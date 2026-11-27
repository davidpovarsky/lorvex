import UIKit
import XCTest

/// Supplemental native gestures against ordinary tasks in the existing host store.
/// The original workspace, Matrix and Hanlin acceptance methods remain separate.
final class TaskWorkspaceInteractionIntegrationTests: XCTestCase {
  @MainActor
  func testRealZoomAndBoardActionsPreserveCanonicalTasks() async throws {
    continueAfterFailure = false
    let language = try XCTUnwrap(Language(rawValue:
      ProcessInfo.processInfo.environment["LORVEX_TEST_LANGUAGE"] ?? "en"))
    let app = XCUIApplication()
    app.launchArguments = [
      "-setupCompleted", "YES", "-AppleLanguages", "(\(language.rawValue))", "-AppleLocale", language.locale
    ]
    app.launchEnvironment["LORVEX_CLOUD_SYNC"] = "off"
    app.launch()
    openWorkspace(app, language: language)
    selectMode("table", app: app)
    let prefix = language.prefix + String(UUID().uuidString.prefix(8))
    let title = prefix + language.delivery
    let prerequisiteTitle = prefix + language.preparation
    createTask(app, title: title)
    setSearch(title, app: app, language: language)
    let taskID = try identifier(for: title, app: app)
    createTask(app, title: prerequisiteTitle)
    setSearch(prerequisiteTitle, app: app, language: language)
    let prerequisiteID = try identifier(for: prerequisiteTitle, app: app)
    XCTAssertNotEqual(taskID, prerequisiteID)
    setSearch(title, app: app, language: language)
    tapVisible(app.buttons["task-workspace.date." + taskID], app: app)
    setDatePresence(true, app: app)
    app.buttons["task-workspace.date.save"].tap()
    XCTAssertTrue(app.buttons["task-workspace.date.save"].waitForNonExistence(timeout: 10))
    setSearch(prefix, app: app, language: language)

    // Fit establishes a visible baseline only. The measured change below must
    // come from a real two-finger pinch, before using any task hit target.
    selectMode("graph", app: app)
    app.buttons["task-workspace.graph.arrange"].tap()
    app.buttons["task-workspace.graph.fit"].tap()
    let flowCanvas = element("task-workspace.graph.canvas", app: app)
    let flowTask = app.buttons["task-workspace.open." + taskID]
    let flowBefore = try await stableFrames([flowTask], app: app)[0]
    XCTAssertGreaterThan(flowBefore.width, 40)
    capture(app, "Lorvex Zoom \(language.rawValue) - Flow before real pinch")
    flowCanvas.pinch(withScale: 0.75, velocity: -0.6)
    try await until("Flow must visibly zoom out after the actual pinch") {
      flowTask.frame.width < flowBefore.width * 0.92
    }
    let flowAfter = try await stableFrames([flowTask], app: app)[0]
    let flowRatio = flowAfter.width / flowBefore.width
    XCTAssertGreaterThan(flowRatio, 0.45)
    XCTAssertLessThan(flowRatio, 0.92)
    tapVisible(flowTask, app: app)
    assertDetail(title, app: app)
    editDetailDay("due", offset: 1, save: true, app: app, language: language)
    editDetailDay("doOn", offset: 0, save: true, app: app, language: language)
    let savedDueDetail = app.buttons["task.detail.row.due"].label
    let savedPlannedDetail = app.buttons["task.detail.row.doOn"].label
    XCTAssertFalse(savedDueDetail.isEmpty)
    XCTAssertFalse(savedPlannedDetail.isEmpty)
    closeDetail(app)
    let flowAfterDates = try await stableFrames([flowTask], app: app)[0]
    XCTAssertEqual(flowAfterDates.width, flowAfter.width, accuracy: 3,
      "Canonical date edits must not replace the active zoomed Flow viewport.")

    let output = element("task-workspace.graph.handle.out." + prerequisiteID, app: app)
    let input = element("task-workspace.graph.handle.in." + taskID, app: app)
    _ = try await stableFrames([output, input], app: app)
    tapTargetIsVisible(output, app: app)
    tapTargetIsVisible(input, app: app)
    output.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo:
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    assertConnection(prerequisiteID, taskID, app: app)
    let prerequisiteComplete = app.buttons["task-workspace.complete." + prerequisiteID]
    tapVisible(prerequisiteComplete, app: app)
    try await until("The zoomed Flow completion hit target must update its canonical task") {
      prerequisiteComplete.label == language.reopenTask
    }
    try assertWorkspacePresentationFits(app)
    capture(app, "Lorvex Zoom \(language.rawValue) - Flow postzoom canonical dates and connector drag")

    // Eight real scoped tasks produce a useful dense-label source screenshot.
    // No seed hook, direct database mutation, or alternate task store is used.
    selectMode("table", app: app)
    var scopedIDs = [taskID, prerequisiteID]
    for index in 1...6 {
      let name = prefix + language.denseTask(index)
      createTask(app, title: name)
      setSearch(name, app: app, language: language)
      scopedIDs.append(try identifier(for: name, app: app))
    }
    XCTAssertEqual(Set(scopedIDs).count, 8)
    setSearch(prefix, app: app, language: language)
    selectMode("network", app: app)
    let networkCanvas = element("task-workspace.network.canvas", app: app)
    app.buttons["task-workspace.network.fit"].tap()
    let nodes = scopedIDs.map { app.buttons["task-workspace.open." + $0] }
    let networkBefore = try await stableFrames(nodes, app: app)
    let pair = farthestPair(networkBefore)
    let beforeDistance = distance(networkBefore[pair.0], networkBefore[pair.1])
    XCTAssertGreaterThan(beforeDistance, 60)
    capture(app, "Lorvex Zoom \(language.rawValue) - Network dense labels before real pinch")
    networkCanvas.pinch(withScale: 0.75, velocity: -0.6)
    try await until("Network must change node separation after the actual pinch") {
      distance(nodes[pair.0].frame, nodes[pair.1].frame) < beforeDistance * 0.92
    }
    let networkAfter = try await stableFrames(nodes, app: app)
    let networkRatio = distance(networkAfter[pair.0], networkAfter[pair.1]) / beforeDistance
    XCTAssertGreaterThan(networkRatio, 0.45)
    XCTAssertLessThan(networkRatio, 0.92)
    let viewportBeforeSelection = networkCanvas.frame
    tapVisible(app.buttons["task-workspace.open." + taskID], app: app)
    assertDetail(title, app: app)
    XCTAssertEqual(app.buttons["task.detail.row.due"].label, savedDueDetail)
    XCTAssertEqual(app.buttons["task.detail.row.doOn"].label, savedPlannedDetail)
    editDetailDay("doOn", offset: 1, save: false, app: app, language: language)
    XCTAssertEqual(app.buttons["task.detail.row.doOn"].label, savedPlannedDetail)
    editDetailDay("due", offset: 0, save: true, app: app, language: language)
    XCTAssertNotEqual(app.buttons["task.detail.row.due"].label, savedDueDetail)
    XCTAssertEqual(app.buttons["task.detail.row.doOn"].label, savedPlannedDetail)
    editDetailDay("due", offset: 1, save: true, app: app, language: language)
    XCTAssertEqual(app.buttons["task.detail.row.due"].label, savedDueDetail)
    closeDetail(app)
    let selectedTitle = app.staticTexts["task-workspace.network.selected-title"]
    XCTAssertTrue(selectedTitle.waitForExistence(timeout: 10))
    XCTAssertEqual(selectedTitle.label, title)
    let networkAfterDates = try await stableFrames(nodes, app: app)
    assertSameFrame(networkCanvas.frame, viewportBeforeSelection, accuracy: 2)
    for (before, after) in zip(networkAfter, networkAfterDates) {
      assertSameFrame(after, before, accuracy: 3)
    }
    XCTAssertFalse(selectedTitle.frame.intersects(networkCanvas.frame),
      "The selected title must occupy its own footer rather than covering the canvas.")
    capture(app, "Lorvex Zoom \(language.rawValue) - Network postzoom date edits and stable selected footer")

    // Schedule two existing dense tasks through the canonical editor so the
    // real two-finger pinch has a fully visible, three-row native surface.
    selectMode("table", app: app)
    for index in 1...2 {
      setSearch(prefix + language.denseTask(index), app: app, language: language)
      tapVisible(app.buttons["task-workspace.date." + scopedIDs[index + 1]], app: app)
      setDatePresence(true, app: app)
      app.buttons["task-workspace.date.save"].tap()
      XCTAssertTrue(app.buttons["task-workspace.date.save"].waitForNonExistence(timeout: 10))
    }
    setSearch(prefix, app: app, language: language)

    // The real shared Timeline control changes the actual chart domain. Its
    // numeric accessibility value binds the observed scale before using a row.
    selectMode("timeline", app: app)
    tapVisible(app.buttons["task-workspace.timeline.fit"], app: app)
    let timelineScale = element("task-workspace.timeline.zoom-scale", app: app)
    XCTAssertTrue(timelineScale.waitForExistence(timeout: 10))
    let timelineBefore = try timelineZoomPercent(timelineScale, language: language)
    XCTAssertEqual(timelineBefore, 100, accuracy: 0.1)
    let timelineFullRange = try timelineVisibleRange(app, language: language)
    capture(app, "Lorvex Zoom \(language.rawValue) - Timeline before real zoom control")
    tapVisible(app.buttons["task-workspace.timeline.zoom-in"], app: app)
    try await until("The actual Timeline control must increase the chart zoom") {
      guard let value = try? timelineZoomPercent(timelineScale, language: language) else { return false }
      return value > timelineBefore
    }
    let timelineControl = try timelineZoomPercent(timelineScale, language: language)
    XCTAssertGreaterThan(timelineControl, timelineBefore)
    XCTAssertLessThanOrEqual(timelineControl, 1_600)
    let timelineControlRange = try timelineVisibleRange(app, language: language)
    XCTAssertLessThan(timelineControlRange.duration, timelineFullRange.duration - 60)
    let timelineEarlierRange = try await moveTimelineToBoundary("earlier", zoom: timelineControl,
      fullRange: timelineFullRange, app: app, language: language)
    let timelineLaterRange = try await moveTimelineToBoundary("later", zoom: timelineControl,
      fullRange: timelineFullRange, app: app, language: language)
    XCTAssertLessThan(timelineEarlierRange.lower, timelineControlRange.lower)
    XCTAssertGreaterThan(timelineLaterRange.lower, timelineEarlierRange.lower)
    tapVisible(app.buttons["task-workspace.timeline.fit"], app: app)
    XCTAssertEqual(try timelineZoomPercent(timelineScale, language: language), 100, accuracy: 0.1)
    let timelineFitRange = try timelineVisibleRange(app, language: language)
    XCTAssertEqual(timelineFitRange.label, timelineFullRange.label,
      "Fit must restore the full observed range after real Earlier and Later actions.")
    tapVisible(app.buttons["task-workspace.timeline.zoom-in"], app: app)
    let timelineBeforePinch = try timelineZoomPercent(timelineScale, language: language)
    XCTAssertEqual(timelineBeforePinch, timelineControl, accuracy: 0.1)
    let timelineRangeBeforePinch = try timelineVisibleRange(app, language: language)
    let timelineChart = element("task-workspace.timeline.chart", app: app)
    try await revealTimelineChart(timelineChart, app: app)
    tapTargetIsVisible(timelineChart, app: app)
    capture(app, "Lorvex Zoom \(language.rawValue) - Timeline control baseline before real pinch")
    timelineChart.pinch(withScale: 1.25, velocity: 0.6)
    try await until("The actual two-finger Timeline pinch must increase the displayed scale") {
      guard let value = try? timelineZoomPercent(timelineScale, language: language) else { return false }
      return value > timelineBeforePinch * 1.05
    }
    let timelineAfter = try timelineZoomPercent(timelineScale, language: language)
    let timelinePinchRatio = timelineAfter / timelineBeforePinch
    XCTAssertGreaterThan(timelinePinchRatio, 1.05)
    // XCTest synthesizes scale on a best-effort basis. The release gate compares
    // this numeric observation with the original two-finger event paths retained
    // by SystemAttachmentLifetime=keepAlways; an assumed request ratio is unsafe.
    let pinchObservation: [String: Any] = [
      "schemaVersion": 1, "requestedScale": 1.25, "requestedVelocity": 0.6,
      "beforePercent": timelineBeforePinch, "afterPercent": timelineAfter,
      "language": language.rawValue
    ]
    let pinchAttachment = XCTAttachment(
      data: try JSONSerialization.data(withJSONObject: pinchObservation, options: [.sortedKeys]),
      uniformTypeIdentifier: "public.json")
    pinchAttachment.name = "Lorvex Timeline pinch measured output"
    pinchAttachment.lifetime = .keepAlways
    add(pinchAttachment)
    XCTAssertLessThanOrEqual(timelineAfter, 1_600)
    let timelineRangeAfterPinch = try timelineVisibleRange(app, language: language)
    XCTAssertNotEqual(timelineRangeAfterPinch.label, timelineRangeBeforePinch.label)
    XCTAssertLessThan(timelineRangeAfterPinch.duration, timelineRangeBeforePinch.duration - 60,
      "The real pinch must narrow the actual rendered date range, not only change a percentage label.")
    assertTimelineRange(timelineRangeAfterPinch, liesWithin: timelineFullRange)
    tapVisible(app.buttons["task-workspace.timeline.inspect." + taskID], app: app)
    let timelineDetail = element("task-workspace.timeline.detail." + taskID, app: app)
    XCTAssertTrue(timelineDetail.waitForExistence(timeout: 10))
    tapVisible(app.buttons["task-workspace.timeline.due." + taskID], app: app)
    setDatePresence(false, app: app)
    app.buttons["task-workspace.date.cancel"].tap()
    XCTAssertTrue(app.buttons["task-workspace.date.cancel"].waitForNonExistence(timeout: 10))
    tapVisible(app.buttons["task-workspace.timeline.planned." + taskID], app: app)
    setDatePresence(false, app: app)
    app.buttons["task-workspace.date.save"].tap()
    XCTAssertTrue(app.buttons["task-workspace.date.save"].waitForNonExistence(timeout: 10))
    app.buttons["task-workspace.timeline.close-actions"].tap()
    XCTAssertEqual(try timelineZoomPercent(timelineScale, language: language), timelineAfter, accuracy: 0.1)
    assertConnection(prerequisiteID, taskID, app: app)
    selectMode("table", app: app)
    setSearch(title, app: app, language: language)
    tapVisible(app.buttons["task-workspace.open." + taskID], app: app)
    assertDetail(title, app: app)
    XCTAssertEqual(app.buttons["task.detail.row.due"].label, savedDueDetail)
    XCTAssertNotEqual(app.buttons["task.detail.row.doOn"].label, savedPlannedDetail,
      "Saving the Timeline planned-date clear must update the original canonical task.")
    editDetailDay("doOn", offset: 0, save: true, app: app, language: language)
    XCTAssertEqual(app.buttons["task.detail.row.doOn"].label, savedPlannedDetail)
    XCTAssertEqual(app.buttons["task.detail.row.due"].label, savedDueDetail)
    closeDetail(app)
    selectMode("timeline", app: app)
    XCTAssertEqual(try timelineZoomPercent(timelineScale, language: language), timelineAfter, accuracy: 0.1,
      "Canonical edits and shared tab remounts must preserve the chosen Timeline viewport.")
    tapVisible(app.buttons["task-workspace.timeline.inspect." + taskID], app: app)
    XCTAssertTrue(timelineDetail.waitForExistence(timeout: 10))
    capture(app, "Lorvex Zoom \(language.rawValue) - Timeline postzoom target and independent date edits")
    app.buttons["task-workspace.timeline.close-actions"].tap()

    setSearch(title, app: app, language: language)
    selectMode("board", app: app)
    try revealBoardLane("open", app: app)
    let column = element("task-workspace.board.column.open", app: app)
    let collapse = app.buttons["task-workspace.board.collapse.open"]
    tapVisible(collapse, app: app)
    XCTAssertTrue(column.waitForNonExistence(timeout: 5))
    _ = try collapsedBoardProof("open", title: language.openLane, taskID: taskID, app: app, language: language)
    tapVisible(app.buttons["lorvex.visual.refresh"], app: app)
    XCTAssertFalse(column.exists)
    _ = try collapsedBoardProof("open", title: language.openLane, taskID: taskID, app: app, language: language)
    let presentation = app.segmentedControls["lorvex.visual.presentation"]
    presentation.buttons[language.matrix].tap()
    XCTAssertTrue(app.textFields["lorvex.matrix.search"].waitForExistence(timeout: 10))
    presentation.buttons[language.workspace].tap()
    XCTAssertTrue(app.buttons["task-workspace.tab.board"].isSelected)
    XCTAssertFalse(column.exists, "The mounted Board must retain collapse through the Matrix presentation.")
    _ = try collapsedBoardProof("open", title: language.openLane, taskID: taskID, app: app, language: language)
    selectMode("table", app: app)
    selectMode("board", app: app)
    try revealBoardLane("open", app: app)
    XCTAssertFalse(column.exists, "Host presentation preferences must retain collapse through a shared tab remount.")
    _ = try collapsedBoardProof("open", title: language.openLane, taskID: taskID, app: app, language: language)
    tapVisible(collapse, app: app)
    XCTAssertTrue(column.waitForExistence(timeout: 5))
    tapVisible(app.buttons["task-workspace.board.actions." + taskID], app: app)
    tapVisible(app.buttons[language.openTask], app: app)
    assertDetail(title, app: app)
    XCTAssertEqual(app.buttons["task.detail.row.due"].label, savedDueDetail)
    XCTAssertEqual(app.buttons["task.detail.row.doOn"].label, savedPlannedDetail)
    closeDetail(app)
    tapVisible(app.buttons["task-workspace.board.actions." + taskID], app: app)
    tapVisible(app.buttons["task-workspace.lane-choice." + taskID + ".completed"], app: app)
    selectMode("table", app: app)
    let lane = app.buttons["task-workspace.lane." + taskID]
    try await until("The Board menu must commit the actual completed lane") { lane.label == language.completedLane }
    let savedDue = app.buttons["task-workspace.date." + taskID].label
    capture(app, "Lorvex Zoom \(language.rawValue) - Board menu commits canonical completion")
    selectMode("board", app: app)
    try revealBoardLane("completed", app: app)
    let completedColumn = element("task-workspace.board.column.completed", app: app)
    XCTAssertTrue(completedColumn.waitForExistence(timeout: 5))
    tapVisible(app.buttons["task-workspace.board.collapse.completed"], app: app)
    XCTAssertTrue(completedColumn.waitForNonExistence(timeout: 5))
    let boardBeforeRestart = try collapsedBoardProof("completed", title: language.completedLane,
      taskID: taskID, app: app, language: language)
    capture(app, "Lorvex Zoom \(language.rawValue) - Board collapsed before cold restart")

    app.terminate()
    app.launch()
    openWorkspace(app, language: language)
    selectMode("table", app: app)
    setSearch(title, app: app, language: language)
    XCTAssertEqual(try identifier(for: title, app: app), taskID)
    XCTAssertEqual(app.buttons["task-workspace.lane." + taskID].label, language.completedLane)
    XCTAssertEqual(app.buttons["task-workspace.date." + taskID].label, savedDue)
    assertConnection(prerequisiteID, taskID, app: app)
    selectMode("timeline", app: app)
    XCTAssertEqual(try timelineZoomPercent(element("task-workspace.timeline.zoom-scale", app: app), language: language),
      timelineAfter, accuracy: 0.1, "Timeline zoom must survive the actual cold app restart.")
    tapVisible(app.buttons["task-workspace.timeline.inspect." + taskID], app: app)
    XCTAssertTrue(element("task-workspace.timeline.detail." + taskID, app: app).waitForExistence(timeout: 10))
    app.buttons["task-workspace.timeline.close-actions"].tap()
    selectMode("board", app: app)
    try revealBoardLane("completed", app: app)
    XCTAssertFalse(completedColumn.exists,
      "The real cold app restart must restore the collapsed Completed column from the same host scope.")
    let boardAfterRestart = try collapsedBoardProof("completed", title: language.completedLane,
      taskID: taskID, app: app, language: language)
    capture(app, "Lorvex Zoom \(language.rawValue) - Board collapsed after cold restart")
    tapVisible(app.buttons["task-workspace.board.collapse.completed"], app: app)
    XCTAssertTrue(completedColumn.waitForExistence(timeout: 5))
    tapVisible(app.buttons["task-workspace.board.actions." + taskID], app: app)
    tapVisible(app.buttons["task-workspace.lane-choice." + taskID + ".open"], app: app)
    selectMode("table", app: app)
    try await until("The Board menu must reopen the persisted canonical task") {
      app.buttons["task-workspace.lane." + taskID].label == language.openLane
    }
    tapVisible(app.buttons["task-workspace.open." + taskID], app: app)
    assertDetail(title, app: app)
    XCTAssertTrue(app.buttons["task.detail.complete"].exists)
    XCTAssertEqual(app.buttons["task.detail.row.due"].label, savedDueDetail)
    XCTAssertEqual(app.buttons["task.detail.row.doOn"].label, savedPlannedDetail)
    capture(app, "Lorvex Zoom \(language.rawValue) - canonical task reopened with independent dates")
    closeDetail(app)

    let proof: [String: Any] = [
      "sourceSHA": ProcessInfo.processInfo.environment["LORVEX_TEST_SOURCE_SHA"] ?? "unrecorded",
      "runID": ProcessInfo.processInfo.environment["LORVEX_TEST_RUN_ID"] ?? "unrecorded",
      "language": language.rawValue,
      "family": UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
      "taskID": taskID, "prerequisiteID": prerequisiteID, "scopedTaskIDs": scopedIDs,
      "flowPinch": ["requestedScale": 0.75, "observedWidthRatio": flowRatio,
                    "before": frameJSON(flowBefore), "after": frameJSON(flowAfter)],
      "networkPinch": ["requestedScale": 0.75, "observedDistanceRatio": networkRatio,
                       "measuredTaskIDs": [scopedIDs[pair.0], scopedIDs[pair.1]],
                       "before": networkBefore.map(frameJSON), "after": networkAfter.map(frameJSON)],
      "flowPostzoomTargetAndDependencyDrag": true,
      "flowPostzoomCanonicalDateEdits": true,
      "networkPostzoomCanonicalDateEdits": true,
      "networkSelectedFooterAndViewportStable": true,
      "timelineZoom": ["beforePercent": timelineBefore, "controlPercent": timelineControl,
                       "beforePinchPercent": timelineBeforePinch, "afterPercent": timelineAfter,
                       "requestedPinchScale": 1.25, "observedPinchRatio": timelinePinchRatio,
                       "control": "task-workspace.timeline.zoom-in",
                       "pinchSurface": "task-workspace.timeline.chart",
                       "fullRange": timelineFullRange.proof, "controlRange": timelineControlRange.proof,
                       "earlierRange": timelineEarlierRange.proof, "laterRange": timelineLaterRange.proof,
                       "fitRange": timelineFitRange.proof,
                       "beforePinchRange": timelineRangeBeforePinch.proof,
                       "afterPinchRange": timelineRangeAfterPinch.proof],
      "timelineActualPinchAndVisibleRangeVerified": true,
      "timelineEarlierLaterAndFitVerified": true,
      "timelinePostzoomTargetAndCanonicalDateEdits": true,
      "timelineDateCancellationPreserved": true,
      "timelineZoomSurvivedTabRemountAndRestart": true,
      "boardRealOpenAndLaneMenuActions": true,
      "boardCollapseSurvivedRefreshMatrixAndTabRemount": true,
      "boardCollapseSurvivedColdRestart": true,
      "boardCollapse": ["beforeRestart": boardBeforeRestart, "afterRestart": boardAfterRestart],
      "canonicalLaneDatesDependencySurvivedRestart": true,
      "boardMenuReopenedPersistedTask": true,
      "pendingSharedProductRequirements": [] as [String]
    ]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]),
                                  uniformTypeIdentifier: "public.json")
    attachment.name = "Lorvex native interaction acceptance proof"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func until(_ message: String, timeout: TimeInterval = 10,
                     _ predicate: @MainActor () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(100))
    } while ProcessInfo.processInfo.systemUptime < deadline
    XCTFail(message)
    throw AcceptanceError.condition(message)
  }

  @MainActor
  private func stableFrames(_ elements: [XCUIElement], app: XCUIApplication) async throws -> [CGRect] {
    var previous: [CGRect] = []
    var stableSamples = 0
    var result: [CGRect] = []
    try await until("Native hit-target geometry did not become visible and stable") {
      guard elements.allSatisfy({ $0.exists }) else { stableSamples = 0; return false }
      let next = elements.map(\.frame)
      guard next.allSatisfy({ !$0.isEmpty && app.frame.contains($0) }) else {
        stableSamples = 0; previous = next; return false
      }
      if previous.count == next.count,
         zip(previous, next).allSatisfy({ frameDifference($0.0, $0.1) <= 1 }) {
        stableSamples += 1
      } else { stableSamples = 0 }
      previous = next; result = next
      return stableSamples >= 2
    }
    return result
  }

  @MainActor
  private func assertWorkspacePresentationFits(_ app: XCUIApplication) throws {
    let snapshot = try app.snapshot()
    var pending: [any XCUIElementSnapshot] = [snapshot]
    var nodes: [any XCUIElementSnapshot] = []
    while let node = pending.popLast() {
      nodes.append(node)
      pending.append(contentsOf: node.children)
    }
    func required(_ identifier: String) throws -> any XCUIElementSnapshot {
      let matches = nodes.filter { $0.identifier == identifier }
      XCTAssertEqual(matches.count, 1, "Expected one native layout element: " + identifier)
      return try XCTUnwrap(matches.first)
    }
    let picker = try required("lorvex.visual.presentation")
    let workspace = try required("task-workspace")
    let assistant = try required("hanlin.open")
    var segmentFrames: [CGRect] = []
    pending = picker.children
    while let node = pending.popLast() {
      if node.elementType == .button { segmentFrames.append(node.frame) }
      pending.append(contentsOf: node.children)
    }
    XCTAssertEqual(segmentFrames.count, 2)
    let frames = [snapshot.frame, picker.frame, workspace.frame, assistant.frame] + segmentFrames
    guard frames.allSatisfy({
      $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && !$0.isEmpty
    }) else {
      XCTFail("The complete workspace layout must have finite, nonempty native geometry.")
      throw AcceptanceError.condition("Invalid workspace layout geometry")
    }
    let pickerBounds = segmentFrames.reduce(picker.frame) { $0.union($1) }
    let geometry = XCTAttachment(
      string: "app=\(snapshot.frame)\npicker=\(picker.frame)\nsegments=\(segmentFrames)\ncompletePicker=\(pickerBounds)\nworkspace=\(workspace.frame)\nhanlin=\(assistant.frame)")
    geometry.name = "Lorvex selected Flow complete presentation geometry"
    geometry.lifetime = .keepAlways
    add(geometry)
    XCTAssertTrue(snapshot.frame.contains(pickerBounds))
    XCTAssertTrue(snapshot.frame.contains(workspace.frame))
    XCTAssertLessThanOrEqual(pickerBounds.maxY, workspace.frame.minY,
      "The selected workspace must not cover any part of its presentation picker.")
    XCTAssertLessThanOrEqual(workspace.frame.maxY, assistant.frame.minY,
      "The selected workspace and its footer must fit above the Hanlin entry.")
  }

  @MainActor
  private func revealTimelineChart(_ chart: XCUIElement, app: XCUIApplication) async throws {
    let scroll = app.scrollViews["task-workspace.timeline"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 10))
    for attempt in 0...4 {
      let frames = try await stableFrames([scroll, chart], app: app)
      let viewport = frames[0].intersection(app.frame).insetBy(dx: 8, dy: 8)
      let frame = frames[1]
      guard !viewport.isNull, !viewport.isEmpty,
        frame.width <= viewport.width, frame.height <= viewport.height,
        frame.minX >= viewport.minX, frame.maxX <= viewport.maxX
      else {
        XCTFail("The complete Timeline pinch surface cannot fit its actual scroll viewport.")
        throw AcceptanceError.condition("Timeline pinch surface cannot fit")
      }
      if viewport.contains(frame) {
        let geometry = XCTAttachment(
          string: "scroll=\(frames[0])\ninsetViewport=\(viewport)\nchart=\(frame)\nphysicalScrolls=\(attempt)")
        geometry.name = "Lorvex Timeline pinch prepared native geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        return
      }
      guard attempt < 4 else { break }
      let overlap = frame.intersection(viewport)
      guard !overlap.isNull, !overlap.isEmpty else {
        XCTFail("Timeline chart has no visible drag origin.")
        throw AcceptanceError.condition("Timeline chart not visible")
      }
      let lower = viewport.minY - frame.minY
      let upper = viewport.maxY - frame.maxY
      let reserve = min(CGFloat(8), max(0, upper - lower) / 2)
      let requestedDy = frame.maxY > viewport.maxY ? upper - reserve : lower + reserve
      let start = CGPoint(x: overlap.midX, y: overlap.midY)
      let dy = max(viewport.minY - start.y, min(viewport.maxY - start.y, requestedDy))
      let origin = scroll.coordinate(withNormalizedOffset: .zero)
      let from = origin.withOffset(CGVector(
        dx: start.x - frames[0].minX, dy: start.y - frames[0].minY))
      let to = from.withOffset(CGVector(dx: 0, dy: dy))
      from.press(forDuration: 0.05, thenDragTo: to)
      try await until("The physical Timeline scroll did not move the chart into view") {
        guard chart.exists else { return false }
        let current = chart.frame
        return viewport.contains(current)
          || (dy < 0 ? current.minY < frame.minY : current.minY > frame.minY)
      }
    }
    XCTFail("The whole Timeline chart is still clipped after bounded native scrolling.")
    throw AcceptanceError.condition("Timeline chart remains clipped")
  }

  @MainActor
  private func timelineZoomPercent(_ scale: XCUIElement, language: Language) throws -> Double {
    let raw = try XCTUnwrap(scale.value as? String, "Timeline must expose its numeric zoom percentage.")
    let numeric = String(raw.filter { $0.wholeNumberValue != nil || $0 == "." || $0 == "," })
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: language.locale)
    formatter.numberStyle = .decimal
    let value = try XCTUnwrap(formatter.number(from: numeric), "Timeline zoom value is not a localized number: " + raw)
      .doubleValue
    XCTAssertTrue(value.isFinite)
    return value
  }

  private struct TimelineRange {
    let label: String
    let lower: Date
    let upper: Date
    var duration: TimeInterval { upper.timeIntervalSince(lower) }
    var proof: [String: Any] {
      ["label": label, "lowerEpochSeconds": lower.timeIntervalSince1970,
       "upperEpochSeconds": upper.timeIntervalSince1970, "durationSeconds": duration]
    }
  }

  @MainActor
  private func timelineVisibleRange(_ app: XCUIApplication, language: Language) throws -> TimelineRange {
    let range = app.staticTexts["task-workspace.timeline.visible-range"]
    XCTAssertTrue(range.waitForExistence(timeout: 10))
    let label = range.label
    let endpoints = label.components(separatedBy: " – ")
    guard endpoints.count == 2 else {
      XCTFail("Timeline must expose its actual lower and upper dates: " + label)
      throw AcceptanceError.condition("Timeline range endpoints")
    }
    // This is the same locale-aware style used by the real shared range label.
    let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: language.locale))
    let lower = try style.parseStrategy.parse(endpoints[0])
    let upper = try style.parseStrategy.parse(endpoints[1])
    XCTAssertLessThan(lower, upper)
    return TimelineRange(label: label, lower: lower, upper: upper)
  }

  private func assertTimelineRange(_ range: TimelineRange, liesWithin fullRange: TimelineRange) {
    // The actual UI formats to minutes; allow that display precision, not an
    // arbitrary pixel or panning allowance.
    XCTAssertGreaterThanOrEqual(range.lower.timeIntervalSince(fullRange.lower), -60)
    XCTAssertLessThanOrEqual(range.upper.timeIntervalSince(fullRange.upper), 60)
  }

  @MainActor
  private func moveTimelineToBoundary(_ direction: String, zoom: Double, fullRange: TimelineRange,
                                      app: XCUIApplication, language: Language) async throws -> TimelineRange {
    let control = app.buttons["task-workspace.timeline." + direction]
    XCTAssertTrue(control.waitForExistence(timeout: 10))
    XCTAssertTrue(control.isEnabled)
    let initial = try timelineVisibleRange(app, language: language)
    var current = initial
    for _ in 0..<6 where control.isEnabled {
      let previous = current.label
      tapVisible(control, app: app)
      try await until("The actual Timeline date control must change its visible dates") {
        app.staticTexts["task-workspace.timeline.visible-range"].label != previous
      }
      current = try timelineVisibleRange(app, language: language)
      XCTAssertEqual(try timelineZoomPercent(element("task-workspace.timeline.zoom-scale", app: app),
        language: language), zoom, accuracy: 0.1)
      XCTAssertEqual(current.duration, initial.duration, accuracy: 120)
      assertTimelineRange(current, liesWithin: fullRange)
    }
    XCTAssertFalse(control.isEnabled, "The real date control must stop at the task-domain boundary.")
    XCTAssertNotEqual(current.label, initial.label)
    return current
  }

  private func frameDifference(_ a: CGRect, _ b: CGRect) -> CGFloat {
    max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
  }

  private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
    hypot(a.midX - b.midX, a.midY - b.midY)
  }

  private func farthestPair(_ frames: [CGRect]) -> (Int, Int) {
    var result = (0, 1)
    for first in frames.indices {
      for second in frames.indices where second > first {
        if distance(frames[first], frames[second]) > distance(frames[result.0], frames[result.1]) {
          result = (first, second)
        }
      }
    }
    return result
  }

  private func frameJSON(_ frame: CGRect) -> [String: Double] {
    ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
  }

  private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat) {
    XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy)
    XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy)
    XCTAssertEqual(actual.width, expected.width, accuracy: accuracy)
    XCTAssertEqual(actual.height, expected.height, accuracy: accuracy)
  }

  @MainActor
  private func openWorkspace(_ app: XCUIApplication, language: Language) {
    let tab = app.tabBars.buttons[language.tasks].firstMatch
    if tab.waitForExistence(timeout: 15) { tab.tap() }
    else { tapVisible(app.buttons[language.tasks].firstMatch, app: app) }
    tapVisible(app.buttons["lorvex.visual.open"], app: app)
    XCTAssertTrue(app.buttons["task-workspace.create"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func createTask(_ app: XCUIApplication, title: String) {
    app.buttons["task-workspace.create"].tap()
    let field = app.textFields["lorvex.visual.create.title"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap(); field.typeText(title)
    app.buttons["lorvex.visual.create.save"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func identifier(for title: String, app: XCUIApplication) throws -> String {
    let item = app.buttons.matching(NSPredicate(
      format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", title)).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 10))
    let id = String(item.identifier.dropFirst("task-workspace.open.".count))
    XCTAssertFalse(id.isEmpty)
    return id
  }

  @MainActor
  private func setSearch(_ value: String, app: XCUIApplication, language: Language) {
    let clear = app.buttons[language.clearSearch]
    if clear.exists { clear.tap() }
    let field = app.textFields["task-workspace.search"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap(); field.typeText(value + "\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
  }

  @MainActor
  private func selectMode(_ mode: String, app: XCUIApplication) {
    let tab = app.buttons["task-workspace.tab." + mode]
    XCTAssertTrue(tab.waitForExistence(timeout: 10))
    let strip = app.scrollViews.containing(.button, identifier: tab.identifier).firstMatch
    XCTAssertTrue(strip.waitForExistence(timeout: 5))
    for _ in 0..<5 {
      let viewport = strip.frame.intersection(app.frame)
      if !tab.frame.isEmpty && viewport.contains(tab.frame) { break }
      if tab.frame.maxX > viewport.maxX { strip.swipeLeft() }
      else if tab.frame.minX < viewport.minX { strip.swipeRight() }
      else { break }
    }
    tapVisible(tab, app: app)
    expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: tab)
    waitForExpectations(timeout: 5)
    let surface = mode == "graph" || mode == "network" ? "task-workspace.\(mode).canvas" : "task-workspace." + mode
    XCTAssertTrue(element(surface, app: app).waitForExistence(timeout: 10))
  }

  @MainActor
  private func revealBoardLane(_ lane: String, app: XCUIApplication) throws {
    let header = app.buttons["task-workspace.board.collapse." + lane]
    XCTAssertTrue(header.waitForExistence(timeout: 10))
    let scroll = app.scrollViews.containing(.button, identifier: header.identifier).firstMatch
    XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    for _ in 0..<8 {
      let viewport = scroll.frame.intersection(app.frame)
      if !header.frame.isEmpty && viewport.contains(header.frame) { return }
      if header.frame.maxX > viewport.maxX { scroll.swipeLeft(velocity: .slow) }
      else if header.frame.minX < viewport.minX { scroll.swipeRight(velocity: .slow) }
      else { break }
    }
    XCTFail("The native Board lane did not enter the observed viewport: " + lane)
    throw AcceptanceError.condition("Board lane visibility")
  }

  @MainActor
  private func collapsedBoardProof(_ laneID: String, title: String, taskID: String,
                                   app: XCUIApplication, language: Language) throws -> [String: Any] {
    try revealBoardLane(laneID, app: app)
    let header = app.buttons["task-workspace.board.collapse." + laneID]
    tapTargetIsVisible(header, app: app)
    XCTAssertEqual(header.label, language.expandColumn)
    XCTAssertEqual(header.value as? String, title)
    let lane = element("task-workspace.board.lane." + laneID, app: app)
    XCTAssertTrue(lane.exists)
    XCTAssertFalse(lane.frame.isEmpty)
    XCTAssertTrue(lane.frame.intersects(app.frame))
    XCTAssertFalse(element("task-workspace.board.column." + laneID, app: app).exists)
    XCTAssertFalse(app.buttons["task-workspace.open." + taskID].exists,
      "A collapsed lane must hide its card while its own observed Expand control remains visible.")
    return ["laneID": laneID, "headerLabel": header.label, "headerValue": header.value as? String ?? "",
            "headerFrame": frameJSON(header.frame), "laneFrame": frameJSON(lane.frame),
            "headerHittable": header.isHittable, "columnAndTaskAbsent": true]
  }

  @MainActor
  private func assertConnection(_ prerequisite: String, _ dependent: String, app: XCUIApplication) {
    app.buttons["task-workspace.options"].tap()
    app.buttons["task-workspace.connections"].tap()
    let connection = app.buttons["task-workspace.connection.remove.\(prerequisite).\(dependent)"]
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    XCTAssertTrue(connection.isEnabled)
    app.buttons["task-workspace.connection.done"].tap()
    XCTAssertTrue(app.buttons["task-workspace.connection.done"].waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func assertDetail(_ title: String, app: XCUIApplication) {
    let label = app.staticTexts["task.detail.title"]
    XCTAssertTrue(label.waitForExistence(timeout: 10))
    XCTAssertEqual(label.label, title)
    XCTAssertTrue(label.isHittable)
  }

  @MainActor
  private func editDetailDay(_ field: String, offset: Int, save: Bool,
                             app: XCUIApplication, language: Language) {
    tapVisible(app.buttons["task.detail.row." + field], app: app)
    tapVisible(app.buttons["task.field.day.\(offset)"], app: app)
    let done = app.buttons["task.field.done"]
    if save { done.tap() }
    else { app.buttons[language.cancel].firstMatch.tap() }
    XCTAssertTrue(done.waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func closeDetail(_ app: XCUIApplication) {
    app.buttons["lorvex.visual.detail.close"].tap()
    XCTAssertTrue(app.buttons["lorvex.visual.detail.close"].waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func setDatePresence(_ present: Bool, app: XCUIApplication) {
    let row = app.switches["task-workspace.date.toggle"]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    if row.value as? String != (present ? "1" : "0") {
      let native = row.switches.firstMatch
      tapVisible(native, app: app)
      expectation(for: NSPredicate(format: "value == %@", present ? "1" : "0"), evaluatedWith: row)
      waitForExpectations(timeout: 5)
    }
  }

  @MainActor
  private func element(_ id: String, app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  @MainActor
  private func tapTargetIsVisible(_ item: XCUIElement, app: XCUIApplication) {
    XCTAssertTrue(item.waitForExistence(timeout: 10))
    XCTAssertFalse(item.frame.isEmpty)
    XCTAssertTrue(app.frame.contains(item.frame), "Native target is outside the observed app viewport: " + item.identifier)
    XCTAssertTrue(item.isHittable)
  }

  @MainActor
  private func tapVisible(_ item: XCUIElement, app: XCUIApplication) {
    tapTargetIsVisible(item, app: app)
    item.tap()
  }

  @MainActor
  private func capture(_ app: XCUIApplication, _ name: String) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = name + " hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name; image.lifetime = .keepAlways; add(image)
  }

  private enum AcceptanceError: Error { case condition(String) }
  private enum Language: String {
    case en, he
    var locale: String { self == .he ? "he_IL" : "en_US" }
    var tasks: String { self == .he ? "משימות" : "Tasks" }
    var prefix: String { self == .he ? "בדיקת מחוות " : "Gesture acceptance " }
    var delivery: String { self == .he ? " מסירת הפרויקט" : " project delivery" }
    var preparation: String { self == .he ? " הכנת הפרויקט" : " project preparation" }
    func denseTask(_ index: Int) -> String {
      self == .he ? " תכנון מפורט ומשימה קשורה \(index)" : " detailed planning and related task \(index)"
    }
    var clearSearch: String { self == .he ? "ניקוי חיפוש" : "Clear search" }
    var openTask: String { self == .he ? "פתיחת משימה" : "Open task" }
    var reopenTask: String { self == .he ? "פתיחת המשימה מחדש" : "Reopen task" }
    var openLane: String { self == .he ? "פתוחות" : "Open" }
    var completedLane: String { self == .he ? "הושלמו" : "Completed" }
    var matrix: String { self == .he ? "מטריצה" : "Matrix" }
    var workspace: String { self == .he ? "מרחב משימות" : "Task workspace" }
    var cancel: String { self == .he ? "ביטול" : "Cancel" }
    var expandColumn: String { self == .he ? "הרחבת העמודה" : "Expand column" }
  }
}
