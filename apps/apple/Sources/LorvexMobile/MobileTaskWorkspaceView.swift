import LorvexCore
import SwiftUI
import TaskVisualizationKit

/// The same live task workspace is mounted in navigation and in Hanlin chat.
/// The view owns only its projection and presentation, never persisted tasks.
@MainActor
public struct MobileTaskWorkspaceView: View {
  private let store: MobileStore
  private let initialPresentation: TaskWorkspacePresentation
  private let rootTaskID: String?
  private let listID: String?
  private let embedded: Bool
  @State private var snapshot: TaskWorkspaceSnapshot?
  @State private var loadError: String?
  @State private var loadID: UUID?
  @State private var sheet: WorkspaceSheet?

  /// String boundary keeps the app executable from linking a second static
  /// copy of the visualization package already owned by LorvexMobile.
  public init(
    store: MobileStore, presentationName: String = "graph",
    rootTaskID: String? = nil, listID: String? = nil, embedded: Bool = false
  ) {
    self.init(
      store: store, initialPresentation: TaskWorkspacePresentation(rawValue: presentationName) ?? .graph,
      rootTaskID: rootTaskID, listID: listID, embedded: embedded)
  }

  public init(
    store: MobileStore, initialPresentation: TaskWorkspacePresentation,
    rootTaskID: String? = nil, listID: String? = nil, embedded: Bool = false
  ) {
    self.store = store
    self.initialPresentation = initialPresentation
    self.rootTaskID = rootTaskID
    self.listID = listID
    self.embedded = embedded
  }

  public var body: some View {
    Group {
      if embedded { workspace }
      else {
        workspace
          .navigationTitle(MobileTaskWorkspaceCopy.title)
          .toolbar {
            Button(MobileTaskWorkspaceCopy.refresh, systemImage: "arrow.clockwise") {
              Task { await reload() }
            }
            .accessibilityIdentifier("lorvex.visual.refresh")
          }
      }
    }
  }

  private var workspace: some View {
    VStack(spacing: 0) {
      if let loadError {
        HStack {
          Label(loadError, systemImage: "exclamationmark.triangle")
            .font(.caption)
          Spacer()
          Button(MobileTaskWorkspaceCopy.retry) { Task { await reload() } }
            .accessibilityIdentifier("lorvex.visual.retry")
        }
        .padding(12)
        .background(LorvexDesign.Palette.warning.opacity(0.12))
      }
      if let snapshot {
        TaskWorkspaceView(
          snapshot: snapshot, initialPresentation: initialPresentation, onAction: perform)
      } else if loadError == nil {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          MobileTaskWorkspaceCopy.unavailable, systemImage: "point.3.connected.trianglepath.dotted")
      }
    }
    .task(id: store.taskWorkspaceRevision) { await reload() }
    .sheet(item: $sheet, onDismiss: { Task { await reload() } }) { item in
      switch item {
      case .task(let id):
        NavigationStack {
          MobileStoreRouteView(route: .task(id), store: store)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button(MobileTaskWorkspaceCopy.close) { sheet = nil }
                  .accessibilityIdentifier("lorvex.visual.detail.close")
              }
            }
        }
      case .create:
        MobileVisualTaskCreateSheet(store: store, listID: listID)
      }
    }
    .accessibilityIdentifier("lorvex.visual.workspace")
  }

  private func reload() async {
    let request = UUID()
    loadID = request
    do {
      let next = try await store.loadVisualTaskWorkspace(rootTaskID: rootTaskID, listID: listID)
      guard loadID == request, !Task.isCancelled else { return }
      snapshot = next
      loadError = nil
    } catch is CancellationError {
      return
    } catch {
      guard loadID == request, !Task.isCancelled else { return }
      let message = await store.userFacingBannerMessage(for: error, source: "ios.visual_tasks.read")
      guard loadID == request, !Task.isCancelled else { return }
      loadError = message
    }
  }

  private func perform(_ action: TaskWorkspaceAction) async throws {
    switch action {
    case .openTask(let id): sheet = .task(id)
    case .createTask: sheet = .create
    default:
      do {
        try await store.performVisualTaskAction(action)
      } catch {
        // The upstream Kanban binding is optimistic. Refresh from the database
        // on rejection, then let the kit display the actual failure.
        await reload()
        throw error
      }
      // A read-back failure cannot change a committed write into a retryable
      // failure. reload shows a separate read warning and preserves the view.
      await reload()
    }
  }

  private enum WorkspaceSheet: Identifiable {
    case task(String), create
    var id: String {
      switch self {
      case .task(let id): "task:" + id
      case .create: "create"
      }
    }
  }
}

@MainActor
private struct MobileVisualTaskCreateSheet: View {
  let store: MobileStore
  let listID: String?
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var notes = ""
  @State private var isSaving = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        TextField(MobileTaskWorkspaceCopy.titlePrompt, text: $title)
          .accessibilityIdentifier("lorvex.visual.create.title")
        TextField(MobileTaskWorkspaceCopy.notes, text: $notes, axis: .vertical)
          .lineLimit(3...6)
        if let error { Text(error).foregroundStyle(LorvexDesign.Palette.error) }
      }
      .navigationTitle(MobileTaskWorkspaceCopy.add)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(MobileTaskWorkspaceCopy.cancel) { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(MobileTaskWorkspaceCopy.add) { Task { await save() } }
            .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("lorvex.visual.create.save")
        }
      }
    }
    .interactiveDismissDisabled(isSaving)
  }

  private func save() async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      _ = try await store.createPlannedTask(TaskCreateDraft(
        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
        notes: notes, listID: listID))
      dismiss()
    } catch {
      self.error = await store.userFacingBannerMessage(for: error, source: "ios.visual_tasks.create")
    }
  }
}
