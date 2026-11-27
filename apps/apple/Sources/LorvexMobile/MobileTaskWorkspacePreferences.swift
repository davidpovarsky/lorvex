import CryptoKit
import Foundation
import Observation
import SwiftUI
import TaskVisualizationKit

/// Device-local presentation preferences. Tasks and their synchronization remain
/// in the canonical task store; this object owns only the workspace's view state.
@MainActor
@Observable
public final class MobileTaskWorkspacePreferences {
  public private(set) var accountID: String?
  private var accountGeneration = UUID()
  private var changeID = UUID()
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var accountIDProvider: (@MainActor () -> String?)?

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// The app supplies a live identity read so an old binding is fenced even
  /// before SwiftUI delivers its account-change observation.
  public func followAccount(_ provider: @escaping @MainActor () -> String?) {
    accountIDProvider = provider
    accountGeneration = UUID()
    selectAccount(provider())
  }

  /// Never copies local or previous-account preferences into the new scope.
  public func selectAccount(_ accountID: String?) {
    if let accountIDProvider, accountIDProvider() != accountID { return }
    guard self.accountID != accountID else { return }
    accountDidChange(accountID)
  }

  /// Called synchronously by the account owner for every identity assignment,
  /// including returning to the same account before SwiftUI can render.
  public func accountDidChange(_ accountID: String?) {
    self.accountID = accountID
    accountGeneration = UUID()
  }

  struct Snapshot: Equatable, Sendable {
    let presentationState: TaskWorkspacePresentationState
    let isWritable: Bool
    fileprivate let scope: Scope
    fileprivate let accountGeneration: UUID

    var storageKey: String { scope.storageKey }
  }

  fileprivate struct Scope: Hashable, Sendable {
    let accountID: String?
    let rootTaskID: String?
    let listID: String?

    var storageKey: String {
      // Length-prefix the UTF-8 strings and distinguish nil from the empty
      // string. Neither account nor task identifiers appear in defaults keys.
      var value = "lorvex-workspace-presentation-scope-v1;"
      for part in [accountID, rootTaskID, listID] {
        if let part { value += "s\(part.utf8.count):\(part);" }
        else { value += "n;" }
      }
      let digest = SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }.joined()
      return "lorvex.taskWorkspace.presentation." + digest
    }
  }

  func snapshot(
    accountID: String?, rootTaskID: String? = nil, listID: String? = nil
  ) -> Snapshot {
    _ = changeID
    let scope = Scope(accountID: accountID, rootTaskID: rootTaskID, listID: listID)
    let generation = accountGeneration
    let state = isActive(scope, generation: generation) ? read(scope) : nil
    return Snapshot(
      presentationState: state ?? .init(), isWritable: state != nil,
      scope: scope, accountGeneration: generation)
  }

  /// A binding keeps its original identity lease, but its displayed baseline
  /// advances after a read or admitted write. It works before a parent rerender.
  func binding(
    accountID: String?, rootTaskID: String? = nil, listID: String? = nil,
    visibleLaneIDs: Set<String>
  ) -> Binding<TaskWorkspacePresentationState> {
    let lease = BindingLease(
      owner: self, snapshot: snapshot(accountID: accountID, rootTaskID: rootTaskID, listID: listID),
      visibleLaneIDs: visibleLaneIDs)
    return Binding(get: { lease.read() }, set: { lease.write($0) })
  }

  @MainActor
  private final class BindingLease {
    private weak var owner: MobileTaskWorkspacePreferences?
    private var previous: Snapshot
    private let scope: Scope
    private let generation: UUID
    private let visibleLaneIDs: Set<String>

    init(owner: MobileTaskWorkspacePreferences, snapshot: Snapshot, visibleLaneIDs: Set<String>) {
      self.owner = owner
      previous = snapshot
      scope = snapshot.scope
      generation = snapshot.accountGeneration
      self.visibleLaneIDs = visibleLaneIDs
    }

    func read() -> TaskWorkspacePresentationState {
      guard let owner, owner.isActive(scope, generation: generation) else { return .init() }
      previous = owner.snapshot(
        accountID: scope.accountID, rootTaskID: scope.rootTaskID, listID: scope.listID)
      return previous.presentationState
    }

    func write(_ proposed: TaskWorkspacePresentationState) {
      guard let owner, owner.isActive(scope, generation: generation),
        owner.setPresentationState(proposed, from: previous, visibleLaneIDs: visibleLaneIDs)
      else { return }
      previous = owner.snapshot(
        accountID: scope.accountID, rootTaskID: scope.rootTaskID, listID: scope.listID)
    }
  }

  /// Apply the user's changed fields to the latest record. An expanded sheet
  /// and its embedded card may both have captured the previous value: collapsing
  /// one lane must not undo the other's lane or Timeline update.
  @discardableResult
  func setPresentationState(
    _ proposed: TaskWorkspacePresentationState,
    from previous: Snapshot,
    visibleLaneIDs: Set<String>
  ) -> Bool {
    guard previous.isWritable,
      isActive(previous.scope, generation: previous.accountGeneration),
      Self.isValid(zoom: proposed.timelineViewport.zoom, centerDate: proposed.timelineViewport.centerDate),
      let current = read(previous.scope)
    else { return false }

    let old = previous.presentationState
    let expanded = old.collapsedLaneIDs.subtracting(proposed.collapsedLaneIDs)
      .intersection(visibleLaneIDs)
    let collapsed = proposed.collapsedLaneIDs.subtracting(old.collapsedLaneIDs)
      .intersection(visibleLaneIDs)
    let lanes = current.collapsedLaneIDs.subtracting(expanded).union(collapsed)
    let viewport = proposed.timelineViewport == old.timelineViewport
      ? current.timelineViewport : proposed.timelineViewport
    let next = TaskWorkspacePresentationState(
      collapsedLaneIDs: lanes, timelineViewport: viewport)

    guard next != current else {
      if current != old { changeID = UUID() }
      return true
    }
    let record = Record(
      formatVersion: 1, collapsedLaneIDs: next.collapsedLaneIDs.sorted(),
      timelineViewport: StoredViewport(
        zoom: next.timelineViewport.zoom, centerDate: next.timelineViewport.centerDate))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(record) else { return false }
    defaults.set(data, forKey: previous.scope.storageKey)
    changeID = UUID()
    return true
  }

  private func isActive(_ scope: Scope, generation: UUID) -> Bool {
    guard scope.accountID == accountID, generation == accountGeneration else { return false }
    if let accountIDProvider { return accountIDProvider() == scope.accountID }
    return true
  }

  private struct StoredViewport: Codable {
    let zoom: Double
    let centerDate: Date?
  }

  private struct Record: Codable {
    let formatVersion: Int
    let collapsedLaneIDs: [String]
    let timelineViewport: StoredViewport
  }

  private func read(_ scope: Scope) -> TaskWorkspacePresentationState? {
    guard let object = defaults.object(forKey: scope.storageKey) else { return .init() }
    // Fail closed for malformed records and future fields, including unknown
    // nested fields. The original defaults object is never rewritten on read.
    guard let data = object as? Data,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(json.keys) == ["formatVersion", "collapsedLaneIDs", "timelineViewport"],
      let viewportJSON = json["timelineViewport"] as? [String: Any],
      Set(viewportJSON.keys).isSubset(of: ["zoom", "centerDate"]),
      let record = try? JSONDecoder().decode(Record.self, from: data),
      record.formatVersion == 1,
      Set(record.collapsedLaneIDs).count == record.collapsedLaneIDs.count,
      Self.isValid(zoom: record.timelineViewport.zoom, centerDate: record.timelineViewport.centerDate)
    else { return nil }
    let viewport = TaskTimelineViewport(
      zoom: record.timelineViewport.zoom, centerDate: record.timelineViewport.centerDate)
    return TaskWorkspacePresentationState(
      collapsedLaneIDs: Set(record.collapsedLaneIDs), timelineViewport: viewport)
  }

  private static func isValid(zoom: Double, centerDate: Date?) -> Bool {
    zoom.isFinite && zoom >= 1 && zoom <= 16
      && (centerDate?.timeIntervalSinceReferenceDate.isFinite ?? true)
  }
}

private struct MobileTaskWorkspaceAccountIDKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

public extension EnvironmentValues {
  /// Lorvex cloud identity; nil is an explicitly separate local scope.
  var lorvexTaskWorkspaceAccountID: String? {
    get { self[MobileTaskWorkspaceAccountIDKey.self] }
    set { self[MobileTaskWorkspaceAccountIDKey.self] = newValue }
  }
}
