import Foundation
import LorvexCore
import TaskVisualizationKit
import Testing
@testable import LorvexMobile

/// Supplemental presentation acceptance; no original workspace catalog changes.
@MainActor
struct MobileTaskWorkspacePreferencesTests {
  private func fixture() throws -> (suite: String, defaults: UserDefaults, store: MobileStore) {
    let suite = "workspace-presentation-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    let core = try SwiftLorvexCoreService.inMemory()
    return (suite, defaults, MobileStore(core: core, defaults: defaults))
  }

  @Test func coldStoreRecreationRestoresCollapsedLanesAndTimelineWithoutPruningAbsentLanes() throws {
    let fixture = try fixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let owner = fixture.store.taskWorkspacePreferences
    owner.selectAccount("account-a")
    let initial = owner.snapshot(accountID: "account-a", listID: "list-a")
    let center = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let viewport = TaskTimelineViewport(zoom: 4, centerDate: center)
    #expect(owner.setPresentationState(
      .init(collapsedLaneIDs: ["open", "later"], timelineViewport: viewport),
      from: initial, visibleLaneIDs: ["open", "later", "done"]))

    // The later lane is temporarily absent from this filtered projection.
    let filtered = owner.snapshot(accountID: "account-a", listID: "list-a")
    #expect(owner.setPresentationState(
      .init(collapsedLaneIDs: ["done"], timelineViewport: viewport),
      from: filtered, visibleLaneIDs: ["open", "done"]))

    let reopenedDefaults = try #require(UserDefaults(suiteName: fixture.suite))
    let reopenedCore = try SwiftLorvexCoreService.inMemory()
    let reopenedStore = MobileStore(core: reopenedCore, defaults: reopenedDefaults)
    let reopened = reopenedStore.taskWorkspacePreferences
    reopened.selectAccount("account-a")
    let restored = reopened.snapshot(accountID: "account-a", listID: "list-a")
    #expect(restored.isWritable)
    #expect(restored.presentationState.collapsedLaneIDs == ["later", "done"])
    #expect(restored.presentationState.timelineViewport == viewport)
  }

  @Test func embeddedAndExpandedUpdatesMergeIndependentLanesAndViewportAndFit() throws {
    let fixture = try fixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let embedded = fixture.store.taskWorkspacePreferences
    let expanded = fixture.store.taskWorkspacePreferences
    #expect(embedded === expanded)
    let first = embedded.binding(
      accountID: nil, rootTaskID: "task-a", visibleLaneIDs: ["open", "done"])
    let second = expanded.binding(
      accountID: nil, rootTaskID: "task-a", visibleLaneIDs: ["open", "done"])
    first.wrappedValue = .init(collapsedLaneIDs: ["open"])
    #expect(first.wrappedValue.collapsedLaneIDs == ["open"])
    let viewport = TaskTimelineViewport(
      zoom: 8, centerDate: Date(timeIntervalSinceReferenceDate: 810_000_000))
    // This second binding still owns its initial baseline. Its viewport update
    // must not erase the first binding's committed collapse.
    second.wrappedValue = .init(timelineViewport: viewport)
    #expect(second.wrappedValue.collapsedLaneIDs == ["open"])
    // The first binding has not read the peer's viewport yet.
    first.wrappedValue = .init(collapsedLaneIDs: ["open", "done"])
    #expect(first.wrappedValue.collapsedLaneIDs == ["open", "done"])
    #expect(first.wrappedValue.timelineViewport == viewport)

    // Two more get/modify/set cycles use this same Binding instance, without
    // recreating either binding or running a parent SwiftUI body.
    var next = first.wrappedValue
    next.collapsedLaneIDs.remove("open")
    first.wrappedValue = next
    #expect(first.wrappedValue.collapsedLaneIDs == ["done"])
    next = first.wrappedValue
    next.collapsedLaneIDs.insert("open")
    first.wrappedValue = next
    #expect(first.wrappedValue.collapsedLaneIDs == ["open", "done"])
    #expect(first.wrappedValue.timelineViewport == viewport)

    var fitted = second.wrappedValue
    fitted.timelineViewport = .init()
    second.wrappedValue = fitted
    #expect(second.wrappedValue.timelineViewport == TaskTimelineViewport())
    #expect(first.wrappedValue.timelineViewport == TaskTimelineViewport())
    #expect(first.wrappedValue.collapsedLaneIDs == ["open", "done"])
  }

  @Test func accountAndTaskContextScopesNeverCopyPresentationState() throws {
    let fixture = try fixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let owner = fixture.store.taskWorkspacePreferences
    let local = owner.snapshot(accountID: nil)
    #expect(owner.setPresentationState(
      .init(collapsedLaneIDs: ["local"]), from: local, visibleLaneIDs: ["local"]))
    owner.selectAccount("account-a")
    let account = owner.snapshot(accountID: "account-a")
    #expect(account.presentationState == TaskWorkspacePresentationState())
    #expect(owner.setPresentationState(
      .init(collapsedLaneIDs: ["account"]), from: account, visibleLaneIDs: ["account"]))
    let root = owner.snapshot(accountID: "account-a", rootTaskID: "same-id")
    let list = owner.snapshot(accountID: "account-a", listID: "same-id")
    let emptyRoot = owner.snapshot(accountID: "account-a", rootTaskID: "")
    #expect(root.storageKey != list.storageKey)
    #expect(emptyRoot.storageKey != account.storageKey)
    #expect(root.presentationState == TaskWorkspacePresentationState())
    #expect(list.presentationState == TaskWorkspacePresentationState())
    #expect(owner.setPresentationState(
      .init(collapsedLaneIDs: ["root"]), from: root, visibleLaneIDs: ["root"]))
    #expect(owner.snapshot(accountID: "account-a", listID: "same-id").presentationState
      == TaskWorkspacePresentationState())

    owner.selectAccount("account-b")
    #expect(owner.snapshot(accountID: "account-b").presentationState == TaskWorkspacePresentationState())
    owner.selectAccount("account-a")
    #expect(owner.snapshot(accountID: "account-a").presentationState.collapsedLaneIDs == ["account"])
    #expect(owner.snapshot(accountID: "account-a", rootTaskID: "same-id")
      .presentationState.collapsedLaneIDs == ["root"])
    owner.selectAccount(nil)
    #expect(owner.snapshot(accountID: nil).presentationState.collapsedLaneIDs == ["local"])
    #expect(!account.storageKey.contains("account-a"))
    #expect(!root.storageKey.contains("same-id"))
  }

  @Test func accountTransitionsFenceOldSnapshotsBeforeObservationAndAfterReturning() async throws {
    let fixture = try fixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let owner = fixture.store.taskWorkspacePreferences
    let core = try #require(fixture.store.assistantCore as? any CloudSyncEngineStore)
    let peer = CloudAccountTestPeer()
    var deliveredAccounts: [String?] = []
    let account = LorvexCloudAccountState(
      transport: makeCloudTransport(core: core, peer: peer), disableICloud: {},
      didChangeAccount: { [weak owner] accountID in
        deliveredAccounts.append(accountID)
        owner?.accountDidChange(accountID)
      }, didSync: {})
    // Initial delivery is explicit; Swift property observers do not run for
    // the account property's initial nil value.
    #expect(deliveredAccounts == [nil])
    owner.followAccount { [weak account] in account?.accountID }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while account.accountID != "account-a", clock.now < deadline {
      try await _Concurrency.Task.sleep(for: .milliseconds(1))
    }
    try #require(account.accountID == "account-a")
    #expect(deliveredAccounts == [nil, "account-a"])
    let original = owner.snapshot(accountID: "account-a")
    let oldBinding = owner.binding(accountID: "account-a", visibleLaneIDs: ["a", "late"])
    oldBinding.wrappedValue = .init(collapsedLaneIDs: ["a"])
    #expect(oldBinding.wrappedValue.collapsedLaneIDs == ["a"])

    // The real account owner delivers A -> signed-out/local -> A. No SwiftUI
    // onChange or manual selectAccount call runs between these transitions.
    await account.signOut()
    #expect(owner.accountID == nil)
    #expect(oldBinding.wrappedValue == TaskWorkspacePresentationState())
    let localBinding = owner.binding(accountID: nil, visibleLaneIDs: ["local"])
    localBinding.wrappedValue = .init(collapsedLaneIDs: ["local"])
    await account.signIn(email: "a@example.test", password: "test-only", register: false)
    try #require(account.accountID == "account-a")
    #expect(deliveredAccounts == [nil, "account-a", nil, "account-a"])
    #expect(owner.accountID == "account-a")
    oldBinding.wrappedValue = .init(collapsedLaneIDs: ["late"])
    localBinding.wrappedValue = .init()
    #expect(!owner.setPresentationState(
      .init(collapsedLaneIDs: ["late"]), from: original, visibleLaneIDs: ["a", "late"]))
    #expect(owner.snapshot(accountID: "account-a").presentationState.collapsedLaneIDs == ["a"])
    await account.signOut()
    #expect(owner.snapshot(accountID: nil).presentationState.collapsedLaneIDs == ["local"])
  }

  @Test func malformedNewerAndUnknownRecordsSurviveReadAndStaleWriteAttempts() throws {
    let fixture = try fixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let owner = fixture.store.taskWorkspacePreferences
    let original = owner.snapshot(accountID: nil)
    let records = [
      "not-json",
      #"{"formatVersion":2,"collapsedLaneIDs":["keep"],"timelineViewport":{"zoom":2}}"#,
      #"{"formatVersion":1,"collapsedLaneIDs":["keep"],"timelineViewport":{"zoom":2},"future":"keep"}"#,
      #"{"formatVersion":1,"collapsedLaneIDs":["keep"],"timelineViewport":{"zoom":2,"future":"keep"}}"#,
      #"{"formatVersion":1,"collapsedLaneIDs":["keep","keep"],"timelineViewport":{"zoom":2}}"#,
      #"{"formatVersion":1,"collapsedLaneIDs":["keep"],"timelineViewport":{"zoom":17}}"#,
    ]
    for record in records {
      let data = Data(record.utf8)
      fixture.defaults.set(data, forKey: original.storageKey)
      #expect(!owner.snapshot(accountID: nil).isWritable)
      #expect(!owner.setPresentationState(
        .init(collapsedLaneIDs: ["replace"]), from: original, visibleLaneIDs: ["replace"]))
      #expect(fixture.defaults.data(forKey: original.storageKey) == data)
    }
    fixture.defaults.set("preserve wrong defaults type", forKey: original.storageKey)
    #expect(!owner.snapshot(accountID: nil).isWritable)
    #expect(!owner.setPresentationState(
      .init(collapsedLaneIDs: ["replace"]), from: original, visibleLaneIDs: ["replace"]))
    #expect(fixture.defaults.string(forKey: original.storageKey) == "preserve wrong defaults type")
  }

  @Test func invalidTimelineValuesCannotReplaceTheLastValidPresentation() throws {
    let fixture = try fixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let owner = fixture.store.taskWorkspacePreferences
    let original = owner.snapshot(accountID: nil)
    #expect(owner.setPresentationState(
      .init(collapsedLaneIDs: ["keep"], timelineViewport: .init(zoom: 3)),
      from: original, visibleLaneIDs: ["keep"]))
    let saved = owner.snapshot(accountID: nil)
    let bytes = try #require(fixture.defaults.data(forKey: saved.storageKey))
    for zoom in [Double.nan, Double.infinity, -Double.infinity, 0, 17] {
      // The SDK initializer normalizes values; its public mutable fields can
      // still receive invalid input later, so exercise that actual boundary.
      var invalid = TaskTimelineViewport()
      invalid.zoom = zoom
      #expect(!owner.setPresentationState(
        .init(timelineViewport: invalid), from: saved, visibleLaneIDs: ["keep"]))
      #expect(fixture.defaults.data(forKey: saved.storageKey) == bytes)
    }
    var invalidDate = TaskTimelineViewport(zoom: 3)
    invalidDate.centerDate = Date(timeIntervalSinceReferenceDate: .infinity)
    #expect(!owner.setPresentationState(
      .init(timelineViewport: invalidDate), from: saved, visibleLaneIDs: ["keep"]))
    #expect(fixture.defaults.data(forKey: saved.storageKey) == bytes)
    #expect(owner.snapshot(accountID: nil).presentationState == saved.presentationState)
  }
}
