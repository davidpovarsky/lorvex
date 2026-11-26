import UIKit
import XCTest

/// Writes through the shipped workspace, checks the original task detail and
/// relaunches the app. These are real local tasks in an isolated test simulator.
/// Set LORVEX_TEST_LANGUAGE in the test runner environment to "en" or "he".
final class TaskWorkspaceIntegrationTests: XCTestCase {
  @MainActor
  func testVisualTaskCompletionSurvivesRelaunch() throws {
    continueAfterFailure = false
    let requestedLanguage = ProcessInfo.processInfo.environment["LORVEX_TEST_LANGUAGE"] ?? "en"
    let language = try XCTUnwrap(
      TestLanguage(rawValue: requestedLanguage),
      "LORVEX_TEST_LANGUAGE must be en or he; refusing to claim another language was tested.")
    let hanlinTitle = language.hanlinTaskPrefix + String(UUID().uuidString.prefix(8))
    let app = XCUIApplication()
    app.launchArguments = [
      "-setupCompleted", "YES", "-AppleLanguages", "(\(language.rawValue))",
      "-AppleLocale", language.locale,
    ]
    app.launchEnvironment["LORVEX_CLOUD_SYNC"] = "off"
    app.launchEnvironment["LORVEX_HANLIN_WORKSPACE_ACCEPTANCE"] = "1"
    app.launchEnvironment["LORVEX_HANLIN_WORKSPACE_TASK_TITLE"] = hanlinTitle
    app.launch()
    openWorkspace(app, language: language)
    let title = language.taskPrefix + String(UUID().uuidString.prefix(8))
    let prerequisite = language.prerequisitePrefix + String(UUID().uuidString.prefix(8))
    createTask(app, title: title)
    createTask(app, title: prerequisite)
    let createdPrerequisite = findTaskButton(named: prerequisite, app: app)
    XCTAssertTrue(createdPrerequisite.waitForExistence(timeout: 10))
    let prerequisiteID = String(createdPrerequisite.identifier.dropFirst("task-workspace.open.".count))

    app.buttons["task-workspace.options"].tap()
    app.buttons[language.editConnections].tap()
    let prerequisitePicker = app.buttons["task-workspace.connection.prerequisite"]
    XCTAssertTrue(prerequisitePicker.waitForExistence(timeout: 5))
    prerequisitePicker.tap()
    selectConnectionChoice(prerequisite, app: app)
    app.buttons["task-workspace.connection.dependent"].tap()
    selectConnectionChoice(title, app: app)
    let connect = app.buttons["task-workspace.connection.add"]
    XCTAssertTrue(connect.isEnabled)
    connect.tap()
    XCTAssertTrue(
      app.buttons[language.removeConnection].firstMatch.waitForExistence(timeout: 10),
      "The real saved dependency must appear in the connection editor.")
    let remove = app.buttons[language.removeConnection].firstMatch
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: remove)
    waitForExpectations(timeout: 10)
    XCTAssertTrue(remove.isHittable)
    remove.tap()
    XCTAssertTrue(remove.waitForNonExistence(timeout: 10))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: connect)
    waitForExpectations(timeout: 10)
    connect.tap()
    XCTAssertTrue(remove.waitForExistence(timeout: 10))
    let done = app.buttons["task-workspace.connection.done"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done)
    waitForExpectations(timeout: 10)
    done.tap()

    selectMode("table", app: app, language: language)
    searchFor(title, app: app)
    let taskButton = findTaskButton(named: title, app: app)
    XCTAssertTrue(taskButton.waitForExistence(timeout: 10))
    let taskID = String(taskButton.identifier.dropFirst("task-workspace.open.".count))

    let hanlinTaskID = verifyHanlinToolWorkspace(app, title: hanlinTitle, language: language)
    XCTAssertNotEqual(hanlinTaskID, taskID)
    XCTAssertNotEqual(hanlinTaskID, prerequisiteID)
    clearSearch(app, language: language)
    searchFor(title, app: app)

    // Schedule a real task so the timeline assertion exercises an actual chart,
    // as well as the date patch and its persistence, rather than an empty state.
    let dueDate = app.buttons["task-workspace.date." + taskID]
    XCTAssertTrue(dueDate.isHittable)
    dueDate.tap()
    let hasDueDate = app.switches[language.hasDueDate]
    XCTAssertTrue(hasDueDate.waitForExistence(timeout: 5))
    XCTAssertEqual(hasDueDate.value as? String, "0")
    attachHierarchy(app, "Lorvex \(language.rawValue) - due toggle before activation")
    tapDateSwitch(hasDueDate, app: app)
    attachHierarchy(app, "Lorvex \(language.rawValue) - due toggle after activation")
    expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: hasDueDate)
    waitForExpectations(timeout: 5)
    let saveDate = app.buttons["task-workspace.date.save"]
    saveDate.tap()
    XCTAssertTrue(saveDate.waitForNonExistence(timeout: 10))
    XCTAssertNotEqual(dueDate.label, language.setDate)
    let savedDateLabel = dueDate.label
    clearSearch(app, language: language)

    var flowConnectionDragVerified = false
    var networkPanFitVerified = false
    var graphFooterOpenVerified = false
    var assistantVerifiedModes = Set<String>()
    for mode in ["graph", "board", "timeline", "network", "table"] {
      selectMode(mode, app: app, language: language)
      if mode == "timeline" {
        XCTAssertTrue(
          app.descendants(matching: .any)
            .matching(identifier: "task-workspace.timeline.chart")
            .firstMatch.waitForExistence(timeout: 10))
        let inspect = app.buttons["task-workspace.timeline.inspect." + taskID]
        XCTAssertTrue(inspect.waitForExistence(timeout: 10))
        inspect.tap()
        let timelineDetail = app.descendants(matching: .any)
          .matching(identifier: "task-workspace.timeline.detail." + taskID).firstMatch
        XCTAssertTrue(timelineDetail.waitForExistence(timeout: 10))
        XCTAssertTrue(app.frame.intersects(timelineDetail.frame))
        let timelineDue = app.buttons["task-workspace.timeline.due." + taskID]
        XCTAssertTrue(timelineDue.isHittable)
        timelineDue.tap()
        let dateToggle = app.switches["task-workspace.date.toggle"]
        XCTAssertTrue(dateToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(dateToggle.value as? String, "1")
        app.buttons["task-workspace.date.cancel"].tap()
        let timelinePlanned = app.buttons["task-workspace.timeline.planned." + taskID]
        XCTAssertTrue(timelinePlanned.waitForExistence(timeout: 5))
        timelinePlanned.tap()
        XCTAssertTrue(dateToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(dateToggle.value as? String, "0")
        tapDateSwitch(dateToggle, app: app)
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: dateToggle)
        waitForExpectations(timeout: 5)
        app.buttons["task-workspace.date.save"].tap()
        XCTAssertTrue(dateToggle.waitForNonExistence(timeout: 10))
        XCTAssertTrue(timelineDetail.waitForExistence(timeout: 10))
        attach(app, "Lorvex \(language.rawValue) - timeline inspector writes the planned date")
        app.buttons["task-workspace.timeline.close-actions"].tap()
      }
      if mode == "graph", UIDevice.current.userInterfaceIdiom == .pad {
        verifyNativeConnectionDrag(
          app, prerequisiteID: prerequisiteID, dependentID: taskID, language: language)
        flowConnectionDragVerified = true
      }
      if mode == "network" || mode == "graph" {
        let node = app.buttons["task-workspace.open." + taskID]
        if mode == "network" {
          XCTAssertTrue(
            node.waitForExistence(timeout: 10),
            "The native graph must expose the real task as an accessible node.")
          verifyNativeNetworkPanAndFit(node, app: app, language: language)
          networkPanFitVerified = true
        } else {
          fitGraphToTask(node, app: app, language: language)
        }
        node.tap()
        XCTAssertTrue(app.buttons["task.detail.complete"].waitForExistence(timeout: 10))
        app.buttons["lorvex.visual.detail.close"].tap()
        XCTAssertTrue(app.buttons["task-workspace.tab." + mode].waitForExistence(timeout: 10))
      }
      verifyAssistantControlDoesNotCoverWorkspace(app, mode: mode, language: language)
      assistantVerifiedModes.insert(mode)
      if mode == "graph" {
        verifyNativeGraphFooterOpen(app, title: title, language: language)
        graphFooterOpenVerified = true
      }
      attach(app, "Lorvex \(language.rawValue) - live \(mode) with connected real tasks")
    }

    searchFor(prerequisite, app: app)
    let prerequisiteButton = findTaskButton(named: prerequisite, app: app)
    XCTAssertTrue(prerequisiteButton.waitForExistence(timeout: 10))
    XCTAssertEqual(prerequisiteButton.identifier, "task-workspace.open." + prerequisiteID)
    let prerequisiteComplete = app.buttons["task-workspace.complete." + prerequisiteID]
    prerequisiteComplete.tap()
    expectation(
      for: NSPredicate(format: "label == %@", language.reopenTask),
      evaluatedWith: prerequisiteComplete)
    waitForExpectations(timeout: 10)

    clearSearch(app, language: language)
    searchFor(title, app: app)
    let lane = app.buttons["task-workspace.lane." + taskID]
    XCTAssertTrue(lane.waitForExistence(timeout: 10))
    lane.tap()
    app.buttons["task-workspace.lane-choice." + taskID + ".in_progress"].tap()
    expectation(for: NSPredicate(format: "label == %@", language.inProgress), evaluatedWith: lane)
    waitForExpectations(timeout: 10)
    let boardDragVerified = try verifyNativeBoardLiftAndDrop(
      app, taskID: taskID, title: title, language: language)
    let boardScrollVerified = try verifyNativeBoardScroll(
      app, primaryTitle: title, language: language)
    let complete = app.buttons["task-workspace.complete." + taskID]
    XCTAssertTrue(complete.isHittable)
    complete.tap()
    expectation(
      for: NSPredicate(format: "label == %@", language.reopenTask), evaluatedWith: complete)
    waitForExpectations(timeout: 10)
    app.buttons["task-workspace.open." + taskID].tap()
    let reopen = app.buttons["task.detail.reopen"]
    XCTAssertTrue(reopen.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["task.detail.row.due"].exists)
    attach(app, "Lorvex \(language.rawValue) - original detail reflects workspace completion and date")
    app.buttons["lorvex.visual.detail.close"].tap()

    app.terminate()
    app.launch()
    openWorkspace(app, language: language)
    selectMode("table", app: app, language: language)
    searchFor(hanlinTitle, app: app)
    XCTAssertTrue(app.buttons["task-workspace.open." + hanlinTaskID].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["task-workspace.complete." + hanlinTaskID].label, language.reopenTask)
    clearSearch(app, language: language)
    searchFor(title, app: app)
    let persisted = app.buttons["task-workspace.open." + taskID]
    XCTAssertTrue(persisted.waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["task-workspace.complete." + taskID].label, language.reopenTask)
    XCTAssertEqual(app.buttons["task-workspace.date." + taskID].label, savedDateLabel)
    selectMode("timeline", app: app, language: language)
    app.buttons["task-workspace.timeline.inspect." + taskID].tap()
    let persistedPlanned = app.buttons["task-workspace.timeline.planned." + taskID]
    XCTAssertTrue(persistedPlanned.waitForExistence(timeout: 10))
    persistedPlanned.tap()
    let persistedPlannedToggle = app.switches["task-workspace.date.toggle"]
    XCTAssertTrue(persistedPlannedToggle.waitForExistence(timeout: 5))
    XCTAssertEqual(persistedPlannedToggle.value as? String, "1")
    app.buttons["task-workspace.date.cancel"].tap()
    app.buttons["task-workspace.timeline.close-actions"].tap()
    selectMode("table", app: app, language: language)
    openConnectionEditor(app)
    let persistedConnection = app.buttons[
      "task-workspace.connection.remove." + prerequisiteID + "." + taskID]
    XCTAssertTrue(persistedConnection.waitForExistence(timeout: 10))
    closeConnectionEditor(app)
    persisted.tap()
    XCTAssertTrue(app.buttons["task.detail.reopen"].waitForExistence(timeout: 10))
    app.buttons["task.detail.reopen"].tap()
    XCTAssertTrue(app.buttons["task.detail.complete"].waitForExistence(timeout: 10))
    attach(app, "Lorvex \(language.rawValue) - persisted task reopened through original editor")
    let proof: [String: Any] = [
      "sourceSHA": ProcessInfo.processInfo.environment["LORVEX_TEST_SOURCE_SHA"] ?? "unrecorded",
      "runID": ProcessInfo.processInfo.environment["LORVEX_TEST_RUN_ID"] ?? "unrecorded",
      "language": language.rawValue,
      "taskID": taskID,
      "prerequisiteID": prerequisiteID,
      "taskTitle": title,
      "dueDateLabel": savedDateLabel,
      "nativeHanlinToolWorkspaceVerified": true,
      "hanlinCreatedTaskID": hanlinTaskID,
      "hanlinCreatedTaskTitle": hanlinTitle,
      "hanlinRoutineWriteAuthorization": "production-automatic",
      "hanlinCreatedTaskPreservedAfterRelaunch": true,
      "nativeNetworkPanFitVerified": networkPanFitVerified,
      "nativeGraphFooterOpenVerified": graphFooterOpenVerified,
      "assistantWorkspaceControlsDoNotOverlap":
        assistantVerifiedModes == Set(["graph", "board", "timeline", "network", "table"]),
      "nativeBoardDragVerified": boardDragVerified,
      "nativeBoardColumnControlsVerified": boardDragVerified,
      "nativeBoardScrollVerified": boardScrollVerified,
      "nativeFlowConnectionDragVerified": flowConnectionDragVerified,
      "dependencyPreservedAfterRelaunch": true,
      "restartObserved": true,
      "completedAfterRelaunch": true,
      "dueDatePreservedAfterRelaunch": true,
      "plannedDatePreservedAfterRelaunch": true,
      "reopenedInCanonicalDetail": true,
    ]
    let encoded = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
    let persistence = XCTAttachment(string: String(decoding: encoded, as: UTF8.self))
    persistence.name = "Lorvex \(language.rawValue) - workspace persistence receipt"
    persistence.lifetime = .keepAlways
    add(persistence)
  }

  @MainActor
  private func verifyHanlinToolWorkspace(
    _ app: XCUIApplication, title: String, language: TestLanguage
  ) -> String {
    let open = app.buttons["hanlin.open"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.tap()
    let editor = app.textViews["hanlin-chat-input"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText(language == .he
      ? "צור משימה בשם \"\(title)\" והצג אותה בטבלה."
      : "Create a task named \"\(title)\" and show it as a table.")
    let send = app.buttons["hanlin.composer.send"]
    XCTAssertTrue(send.isEnabled && send.isHittable)
    send.tap()
    let card = app.otherElements["hanlin.workspace.lorvex-acceptance-workspace"]
    XCTAssertTrue(card.waitForExistence(timeout: 30))
    let completion = app.textViews.matching(
      NSPredicate(format: "label == %@", "Native workspace acceptance completed.")).firstMatch
    XCTAssertTrue(completion.waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["hanlin.error"].exists)
    let created = card.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", title)
    ).firstMatch
    XCTAssertTrue(created.waitForExistence(timeout: 10))
    let taskID = String(created.identifier.dropFirst("task-workspace.open.".count))
    XCTAssertFalse(taskID.isEmpty)
    attachHierarchy(app, "Lorvex \(language.rawValue) - actual Hanlin tool result creates a live card")

    let expand = card.buttons["hanlin.workspace.expand"]
    let transcript = app.scrollViews.containing(.button, identifier: "hanlin.workspace.expand").firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 5))
    for _ in 0..<4 {
      if app.frame.contains(expand.frame), expand.isHittable { break }
      if expand.frame.minY < transcript.frame.minY { transcript.swipeDown() }
      else { transcript.swipeUp() }
    }
    XCTAssertTrue(expand.isHittable)
    expand.tap()
    let expanded = app.otherElements["hanlin.workspace.expanded"]
    XCTAssertTrue(expanded.waitForExistence(timeout: 10))
    let expandedTask = expanded.buttons["task-workspace.open." + taskID]
    XCTAssertTrue(expandedTask.waitForExistence(timeout: 10))
    XCTAssertEqual(expandedTask.label, title)
    expandedTask.tap()
    let complete = app.buttons["task.detail.complete"]
    XCTAssertTrue(complete.waitForExistence(timeout: 10))
    complete.tap()
    XCTAssertTrue(app.buttons["task.detail.reopen"].waitForExistence(timeout: 10))
    attach(app, "Lorvex \(language.rawValue) - Hanlin-created task completed in canonical editor")
    app.buttons["lorvex.visual.detail.close"].tap()
    expectation(for: NSPredicate(format: "label == %@", language.reopenTask),
      evaluatedWith: expanded.buttons["task-workspace.complete." + taskID])
    waitForExpectations(timeout: 10)
    app.buttons["hanlin.workspace.expanded.close"].tap()
    XCTAssertTrue(expanded.waitForNonExistence(timeout: 10))

    // The shipped assistant toolbar opens the same current database as the
    // tool result card. Read the exact tool-created ID through that route too.
    app.buttons["hanlin.workspace.open"].tap()
    let sheet = app.otherElements["hanlin.workspace.sheet"]
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    let toolbarTask = sheet.buttons["task-workspace.open." + taskID]
    fitGraphToTask(toolbarTask, app: app, language: language)
    XCTAssertEqual(toolbarTask.label, title)
    toolbarTask.tap()
    XCTAssertTrue(app.buttons["task.detail.reopen"].waitForExistence(timeout: 10))
    app.buttons["lorvex.visual.detail.close"].tap()
    app.buttons["hanlin.workspace.close"].tap()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    app.buttons["hanlin.close"].tap()
    XCTAssertTrue(open.waitForExistence(timeout: 10))

    clearSearch(app, language: language)
    searchFor(title, app: app)
    let canonical = app.buttons["task-workspace.open." + taskID]
    XCTAssertTrue(canonical.waitForExistence(timeout: 10))
    XCTAssertEqual(canonical.label, title)
    XCTAssertEqual(app.buttons["task-workspace.complete." + taskID].label, language.reopenTask)
    attachHierarchy(app, "Lorvex \(language.rawValue) - main workspace reads exact Hanlin task and saved completion")
    return taskID
  }

  @MainActor
  private func verifyAssistantControlDoesNotCoverWorkspace(
    _ app: XCUIApplication, mode: String, language: TestLanguage
  ) {
    let assistant = app.buttons["hanlin.open"]
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
    let viewport = app.frame
    let assistantFrame = assistant.frame
    XCTAssertTrue(assistant.isHittable && viewport.contains(assistantFrame))
    let workspace = app.descendants(matching: .any)
      .matching(identifier: "lorvex.visual.workspace").firstMatch
    XCTAssertTrue(workspace.waitForExistence(timeout: 10))
    let snapshot: any XCUIElementSnapshot
    do {
      snapshot = try workspace.snapshot()
    } catch {
      XCTFail("The complete native workspace Button snapshot must be available: \(error)")
      return
    }
    // Inspect every actual Button from one coherent native AX tree. Reading each
    // live element attribute separately repeatedly snapshots the whole app.
    var pending = snapshot.children
    var controls: [(identifier: String, label: String, frame: CGRect)] = []
    while let control = pending.popLast() {
      pending.append(contentsOf: control.children)
      guard control.elementType == .button else { continue }
      let frame = control.frame
      guard !frame.isEmpty, viewport.intersects(frame) else { continue }
      controls.append((control.identifier, control.label, frame))
    }
    XCTAssertFalse(controls.isEmpty)
    let frames = controls.map { "\($0.identifier) [\($0.label)]=\($0.frame)" }
    let observation = XCTAttachment(string: "hanlin=\(assistantFrame)\n" + frames.joined(separator: "\n"))
    observation.name = "Lorvex \(language.rawValue) - \(mode) assistant and workspace control frames"
    observation.lifetime = .keepAlways
    add(observation)
    for control in controls {
      XCTAssertFalse(
        assistantFrame.intersects(control.frame),
        "The Hanlin entry must not cover \(control.identifier) [\(control.label)].")
    }
  }

  @MainActor
  private func verifyNativeGraphFooterOpen(
    _ app: XCUIApplication, title: String, language: TestLanguage
  ) {
    let workspace = app.descendants(matching: .any)
      .matching(identifier: "lorvex.visual.workspace").firstMatch
    let open = workspace.buttons[language.openTask]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    XCTAssertTrue(app.frame.contains(open.frame) && open.isHittable)
    XCTAssertFalse(app.buttons["hanlin.open"].frame.intersects(open.frame))
    attachHierarchy(app, "Lorvex \(language.rawValue) - native Flow footer before opening selected task")
    open.tap()
    XCTAssertTrue(app.buttons["task.detail.complete"].waitForExistence(timeout: 10))
    let detailTitle = app.staticTexts["task.detail.title"]
    XCTAssertTrue(detailTitle.waitForExistence(timeout: 10))
    XCTAssertEqual(detailTitle.label, title)
    XCTAssertTrue(detailTitle.isHittable)
    attach(app, "Lorvex \(language.rawValue) - native Flow footer opens the selected canonical task")
    app.buttons["lorvex.visual.detail.close"].tap()
    XCTAssertTrue(app.buttons["task-workspace.tab.graph"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func fitGraphToTask(
    _ node: XCUIElement, app: XCUIApplication, language: TestLanguage
  ) {
    let fit = app.buttons["task-workspace.graph.fit"]
    XCTAssertTrue(fit.waitForExistence(timeout: 10))
    fit.tap()
    XCTAssertTrue(
      node.waitForExistence(timeout: 10),
      "Show whole flow must expose the exact canonical task as an accessible node.")
    XCTAssertTrue(node.isHittable && app.frame.contains(node.frame))
    attachHierarchy(app, "Lorvex \(language.rawValue) - graph Fit exposes the canonical task")
  }

  @MainActor
  private func verifyNativeNetworkPanAndFit(
    _ node: XCUIElement, app: XCUIApplication, language: TestLanguage
  ) {
    let canvas = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.network.canvas").firstMatch
    let fit = app.buttons["task-workspace.network.fit"]
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    XCTAssertTrue(fit.waitForExistence(timeout: 10))
    fit.tap()
    let bounds = canvas.frame.intersection(app.frame)
    let occupied = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "task-workspace.open.")
    ).allElementsBoundByIndex.map { $0.frame } + [fit.frame]
    let before = node.frame
    XCTAssertTrue(node.isHittable && bounds.contains(before))
    let dx: CGFloat = before.midX < bounds.midX ? 80 : -80
    let dy: CGFloat = before.midY < bounds.midY ? 56 : -56
    let fractions: [CGFloat] = [0.15, 0.5, 0.85]
    let candidates = fractions.flatMap { x in
      fractions.map { y in CGPoint(
        x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y) }
    }
    guard let start = candidates.first(where: { point in
      bounds.contains(CGPoint(x: point.x + dx, y: point.y + dy))
        && !occupied.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(point) })
    }) else {
      XCTFail("The visible network must expose empty space for a native pan.")
      return
    }
    let end = CGPoint(x: start.x + dx, y: start.y + dy)
    let observation = XCTAttachment(
      string: "canvas=\(bounds) node=\(before) pan=\(start)->\(end)\n" + app.debugDescription)
    observation.name = "Lorvex \(language.rawValue) - native network observed controls"
    observation.lifetime = .keepAlways
    add(observation)
    let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    origin.withOffset(CGVector(dx: start.x - app.frame.minX, dy: start.y - app.frame.minY))
      .press(forDuration: 0.05, thenDragTo:
        origin.withOffset(CGVector(dx: end.x - app.frame.minX, dy: end.y - app.frame.minY)))
    // Native pointer actions wait for idle. Direct frame reads preserve the
    // physical outcome without nesting accessibility queries in a polling block.
    let afterPan = node.frame
    let panX = afterPan.midX - before.midX
    let panY = afterPan.midY - before.midY
    let pan = XCTAttachment(string: "before=\(before) afterPan=\(afterPan)")
    pan.name = "Lorvex \(language.rawValue) - native network pan measurement"
    pan.lifetime = .keepAlways
    add(pan)
    XCTAssertGreaterThan(panX * panX + panY * panY, 24 * 24)
    attach(app, "Lorvex \(language.rawValue) - native network panned")
    fit.tap()
    let afterFit = node.frame
    let fitX = afterFit.midX - before.midX
    let fitY = afterFit.midY - before.midY
    let fitted = XCTAttachment(string: "before=\(before) afterPan=\(afterPan) afterFit=\(afterFit)")
    fitted.name = "Lorvex \(language.rawValue) - native network Fit measurement"
    fitted.lifetime = .keepAlways
    add(fitted)
    XCTAssertLessThan(fitX * fitX + fitY * fitY, 24 * 24)
    XCTAssertTrue(node.isHittable && bounds.contains(afterFit))
    attach(app, "Lorvex \(language.rawValue) - native network Fit restored")
  }

  private struct NativeBoardCardObservation {
    let id: String
    let frame: CGRect
    let value: String
  }

  @MainActor
  private func nativeBoardCards(
    in column: XCUIElement, viewport: CGRect
  ) throws -> [NativeBoardCardObservation] {
    let snapshot = try column.snapshot()
    var pending = snapshot.children
    var seen = Set<String>()
    var result: [NativeBoardCardObservation] = []
    let prefix = "task-workspace.board.card."
    while let element = pending.popLast() {
      guard element.identifier.hasPrefix(prefix) else {
        pending.append(contentsOf: element.children)
        continue
      }
      // Capture the outer draggable container once. Its native descendants may
      // inherit the same identifier; they are not additional board cards.
      let id = String(element.identifier.dropFirst(prefix.count))
      XCTAssertFalse(id.isEmpty)
      XCTAssertTrue(seen.insert(id).inserted, "Native card IDs must be unique within a column.")
      let frame = element.frame
      let visible = frame.intersection(viewport)
      guard !frame.isEmpty, !visible.isNull,
            visible.width >= 44, visible.height >= 44 else { continue }
      result.append(NativeBoardCardObservation(
        id: id, frame: frame, value: element.value as? String ?? ""))
    }
    return result.sorted { $0.frame.minY < $1.frame.minY }
  }

  @MainActor
  private func verifyNativeBoardLiftAndDrop(
    _ app: XCUIApplication, taskID: String, title: String, language: TestLanguage
  ) throws -> Bool {
    clearSearch(app, language: language)
    let destinationTitle = language.dragTargetPrefix + String(UUID().uuidString.prefix(8))
    createTask(app, title: destinationTitle)
    // Filter the real table before locating the new lazy row.
    searchFor(destinationTitle, app: app)
    let destinationRow = findTaskButton(named: destinationTitle, app: app)
    XCTAssertTrue(destinationRow.waitForExistence(timeout: 10))
    let destinationID = String(destinationRow.identifier.dropFirst("task-workspace.open.".count))
    XCTAssertFalse(destinationID.isEmpty)
    clearSearch(app, language: language)
    selectMode("board", app: app, language: language)
    let destinationColumn = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.column.open").firstMatch
    let sourceColumn = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.column.in_progress").firstMatch
    let collapse = app.buttons["task-workspace.board.collapse.open"]
    XCTAssertTrue(destinationColumn.waitForExistence(timeout: 10))
    XCTAssertTrue(collapse.isHittable)
    collapse.tap()
    XCTAssertTrue(destinationColumn.waitForNonExistence(timeout: 5))
    XCTAssertTrue(collapse.isHittable && app.frame.contains(collapse.frame))
    XCTAssertGreaterThanOrEqual(collapse.frame.width, 44)
    XCTAssertGreaterThanOrEqual(collapse.frame.height, 44)
    attach(app, "Lorvex \(language.rawValue) - collapsed column retains its native expand control")
    collapse.tap()
    XCTAssertTrue(destinationColumn.waitForExistence(timeout: 5))
    XCTAssertTrue(sourceColumn.waitForExistence(timeout: 5))
    let source = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.card." + taskID).firstMatch
    let destination = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.card." + destinationID).firstMatch
    XCTAssertTrue(source.waitForExistence(timeout: 10))
    XCTAssertTrue(destination.waitForExistence(timeout: 10))
    let viewport = app.frame
    let sourceFrame = source.frame
    let destinationFrame = destination.frame
    let sourceVisible = sourceFrame.intersection(sourceColumn.frame).intersection(viewport)
    let destinationVisible = destinationFrame.intersection(destinationColumn.frame).intersection(viewport)
    for visible in [sourceVisible, destinationVisible] {
      XCTAssertFalse(visible.isNull)
      XCTAssertGreaterThanOrEqual(visible.width, 44)
      XCTAssertGreaterThanOrEqual(visible.height, 44)
    }
    XCTAssertTrue(source.isHittable && destination.isHittable)
    let from = source.coordinate(withNormalizedOffset: CGVector(
      dx: (sourceVisible.midX - sourceFrame.minX) / sourceFrame.width,
      dy: (sourceVisible.midY - sourceFrame.minY) / sourceFrame.height))
    let to = destination.coordinate(withNormalizedOffset: CGVector(
      dx: (destinationVisible.midX - destinationFrame.minX) / destinationFrame.width,
      dy: (destinationVisible.midY - destinationFrame.minY) / destinationFrame.height))
    let observation = XCTAttachment(string:
      "source=\(sourceFrame) visible=\(sourceVisible) nativePoint=\(from.screenPoint)\n"
      + "destination=\(destinationFrame) visible=\(destinationVisible) nativePoint=\(to.screenPoint)")
    observation.name = "Lorvex \(language.rawValue) - native Board system lift and drop coordinates"
    observation.lifetime = .keepAlways
    add(observation)
    attach(app, "Lorvex \(language.rawValue) - adjacent native columns before system lift")
    // Each coordinate remains relative to its actual card; XCTest applies the
    // device orientation transform. The hold activates system lift, not a swipe.
    from.press(forDuration: 0.8, thenDragTo: to)
    selectMode("table", app: app, language: language)
    searchFor(title, app: app)
    let lane = app.buttons["task-workspace.lane." + taskID]
    expectation(for: NSPredicate(format: "label == %@", language.openLane), evaluatedWith: lane)
    waitForExpectations(timeout: 10)
    attach(app, "Lorvex \(language.rawValue) - table confirms native Board system drop saved Open")
    return true
  }

  @MainActor
  private func verifyNativeBoardScroll(
    _ app: XCUIApplication, primaryTitle: String, language: TestLanguage
  ) throws -> Bool {
    // Grow the real fixture only when the observed column needs more content,
    // after all five original captures. Never assume a fixed device capacity.
    clearSearch(app, language: language)
    let batch = String(UUID().uuidString.prefix(8))
    var created = 0
    var observedOverflow = false
    var before: [NativeBoardCardObservation] = []
    var viewport = CGRect.zero
    selectMode("board", app: app, language: language)
    let column = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.column.open").firstMatch
    while true {
      XCTAssertTrue(column.waitForExistence(timeout: 10))
      viewport = column.frame.intersection(app.frame)
      before = try nativeBoardCards(in: column, viewport: viewport)
      XCTAssertGreaterThanOrEqual(before.count, 2)
      let ordinals = try before.map { observation -> (index: Int, count: Int) in
        let ordinal = try XCTUnwrap(
          observation.value.split(separator: ",", maxSplits: 1).first,
          "The native card must expose its real index, count and lane.")
        let components = ordinal.split(separator: "/")
          .map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count == 2 else {
          XCTFail("The native card ordinal must contain exactly an index and count: \(observation.value)")
          throw NSError(domain: "NativeBoardAcceptance", code: 1)
        }
        let index = try XCTUnwrap(Int(components[0]))
        let count = try XCTUnwrap(Int(components[1]))
        XCTAssertGreaterThanOrEqual(index, 1)
        XCTAssertGreaterThanOrEqual(count, index)
        return (index, count)
      }
      XCTAssertEqual(Set(ordinals.map { $0.count }).count, 1)
      let total = try XCTUnwrap(ordinals.first?.count)
      let maximumVisibleIndex = ordinals.map { $0.index }.max() ?? 0
      let lowestEdge = before.map { $0.frame.maxY }.max() ?? viewport.minY
      observedOverflow = maximumVisibleIndex < total || lowestEdge > viewport.maxY + 48
      let growth = XCTAttachment(string:
        "created=\(created) column=\(viewport) total=\(total) "
        + "lastVisibleIndex=\(maximumVisibleIndex) lowestEdge=\(lowestEdge) "
        + "overflow=\(observedOverflow)\n"
        + before.map { "\($0.id) value=\($0.value) frame=\($0.frame)" }.joined(separator: "\n"))
      growth.name = "Lorvex \(language.rawValue) - measured Board fixture capacity \(created)"
      growth.lifetime = .keepAlways
      add(growth)
      if observedOverflow { break }
      guard created < 12 else {
        XCTFail("Twelve real additional tasks did not produce measurable native column overflow.")
        return false
      }
      let strides = zip(before, before.dropFirst()).map { $1.frame.minY - $0.frame.minY }
      let measuredStride = max(44, strides.reduce(0, +) / CGFloat(strides.count))
      let needed = max(1, Int(ceil((viewport.maxY + 64 - lowestEdge) / measuredStride)))
      let addition = min(12 - created, needed)
      selectMode("table", app: app, language: language)
      for _ in 0..<addition {
        created += 1
        let fixtureTitle = language.boardScrollPrefix + batch + String(format: " %02d", created)
        createTask(app, title: fixtureTitle)
        searchFor(fixtureTitle, app: app)
        let row = findTaskButton(named: fixtureTitle, app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(row.label, fixtureTitle)
        XCTAssertFalse(String(row.identifier.dropFirst("task-workspace.open.".count)).isEmpty)
        clearSearch(app, language: language)
      }
      selectMode("board", app: app, language: language)
    }
    XCTAssertTrue(observedOverflow)
    let touched = try XCTUnwrap(before.filter { viewport.contains($0.frame) }
      .min { abs($0.frame.midY - viewport.midY) < abs($1.frame.midY - viewport.midY) })
    XCTAssertTrue(touched.value.contains(language.openLane))
    let card = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.card." + touched.id).firstMatch
    XCTAssertTrue(card.isHittable)
    let title = app.buttons["task-workspace.open." + touched.id].label
    XCTAssertFalse(title.isEmpty)
    let beforeObservation = XCTAttachment(string:
      "column=\(viewport) touched=\(touched.id)\n"
      + before.map { "\($0.id) value=\($0.value) frame=\($0.frame)" }.joined(separator: "\n"))
    beforeObservation.name = "Lorvex \(language.rawValue) - native Board card scroll before"
    beforeObservation.lifetime = .keepAlways
    add(beforeObservation)
    attach(app, "Lorvex \(language.rawValue) - native Board before ordinary card swipe")
    let distance = min(CGFloat(120), touched.frame.midY - viewport.minY - 24)
    XCTAssertGreaterThanOrEqual(distance, 48)
    let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = card.coordinate(withNormalizedOffset: CGVector(
      dx: 0.5, dy: 0.5 - distance / touched.frame.height))
    let endpoint = CGPoint(x: touched.frame.midX, y: touched.frame.midY - distance)
    XCTAssertTrue(viewport.contains(endpoint))
    let gesture = XCTAttachment(string:
      "card=\(touched.frame) column=\(viewport) displayStart=\(CGPoint(x: touched.frame.midX, y: touched.frame.midY)) "
      + "displayEnd=\(endpoint) distance=\(distance) nativeStart=\(start.screenPoint) nativeEnd=\(end.screenPoint)")
    gesture.name = "Lorvex \(language.rawValue) - native Board ordinary swipe endpoints"
    gesture.lifetime = .keepAlways
    add(gesture)
    // This short card-centred touch moves through at most 120 display points.
    // It must scroll immediately; the separate 0.8s gesture tests system lift.
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    let after = try nativeBoardCards(in: column, viewport: viewport)
    let beforeIDs = Set(before.map(\.id))
    let afterIDs = Set(after.map(\.id))
    let common = beforeIDs.intersection(afterIDs)
    XCTAssertTrue(common.contains(touched.id), "The touched card must remain observable after the short swipe.")
    XCTAssertGreaterThanOrEqual(common.count, 2)
    let original = before.filter { common.contains($0.id) }
    let scrolled = after.filter { common.contains($0.id) }
    XCTAssertEqual(original.map(\.id), scrolled.map(\.id), "Scrolling must preserve card order.")
    for (first, last) in zip(original, scrolled) {
      XCTAssertFalse(first.value.isEmpty)
      XCTAssertEqual(first.value, last.value, "Native index, count and lane must remain unchanged.")
      XCTAssertEqual(first.frame.midX, last.frame.midX, accuracy: 2)
      XCTAssertLessThan(last.frame.midY - first.frame.midY, -24,
        "The touched card and neighboring cards must move together through native scrolling.")
    }
    let afterObservation = XCTAttachment(string:
      after.map { "\($0.id) value=\($0.value) frame=\($0.frame)" }.joined(separator: "\n"))
    afterObservation.name = "Lorvex \(language.rawValue) - native Board card scroll after"
    afterObservation.lifetime = .keepAlways
    add(afterObservation)
    attach(app, "Lorvex \(language.rawValue) - native Board ordinary swipe scrolls without reordering")
    selectMode("table", app: app, language: language)
    searchFor(title, app: app)
    let lane = app.buttons["task-workspace.lane." + touched.id]
    XCTAssertTrue(lane.waitForExistence(timeout: 10))
    XCTAssertEqual(lane.label, language.openLane)
    attach(app, "Lorvex \(language.rawValue) - canonical lane unchanged after native Board scroll")
    clearSearch(app, language: language)
    searchFor(primaryTitle, app: app)
    return true
  }

  @MainActor
  private func verifyNativeConnectionDrag(
    _ app: XCUIApplication, prerequisiteID: String, dependentID: String,
    language: TestLanguage
  ) {
    let connectionID = "task-workspace.connection.remove." + prerequisiteID + "." + dependentID
    openConnectionEditor(app)
    let connection = app.buttons[connectionID]
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: connection)
    waitForExpectations(timeout: 10)
    connection.tap()
    XCTAssertTrue(connection.waitForNonExistence(timeout: 10))
    closeConnectionEditor(app)
    app.buttons["task-workspace.graph.arrange"].tap()
    app.buttons["task-workspace.graph.fit"].tap()
    let output = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.graph.handle.out." + prerequisiteID).firstMatch
    let input = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.graph.handle.in." + dependentID).firstMatch
    XCTAssertTrue(output.waitForExistence(timeout: 10))
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    XCTAssertTrue(app.frame.contains(output.frame) && app.frame.contains(input.frame))
    XCTAssertTrue(output.isHittable && input.isHittable)
    attach(app, "Lorvex \(language.rawValue) - native Flow endpoints before connecting")
    output.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo:
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    openConnectionEditor(app)
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: connection)
    waitForExpectations(timeout: 10)
    attach(app, "Lorvex \(language.rawValue) - canonical edge saved by native Flow drag")
    closeConnectionEditor(app)
  }

  @MainActor
  private func openConnectionEditor(_ app: XCUIApplication) {
    app.buttons["task-workspace.options"].tap()
    app.buttons["task-workspace.connections"].tap()
    XCTAssertTrue(app.buttons["task-workspace.connection.done"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func closeConnectionEditor(_ app: XCUIApplication) {
    let done = app.buttons["task-workspace.connection.done"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done)
    waitForExpectations(timeout: 10)
    done.tap()
    XCTAssertTrue(done.waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func tapDateSwitch(_ row: XCUIElement, app: XCUIApplication) {
    // SwiftUI exposes the whole Form row as a Switch, with the actual native
    // switch as its descendant. A row-centre pointer tap hits the empty label
    // area. Select the observed native control without assuming an RTL side.
    let control = row.switches.firstMatch
    XCTAssertTrue(control.waitForExistence(timeout: 5))
    XCTAssertTrue(row.frame.contains(control.frame) && app.frame.contains(control.frame))
    XCTAssertTrue(control.isHittable)
    control.tap()
  }

  @MainActor
  private func selectConnectionChoice(_ title: String, app: XCUIApplication) {
    // The native Picker presents its choices inside a collection view. The
    // graph behind the sheet exposes the same real task title, so selecting
    // from every app button is ambiguous once graph accessibility is enabled.
    let choice = app.collectionViews.buttons[title]
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    XCTAssertTrue(choice.isHittable)
    choice.tap()
  }

  @MainActor
  private func createTask(_ app: XCUIApplication, title: String) {
    app.buttons["task-workspace.create"].tap()
    let field = app.textFields["lorvex.visual.create.title"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(title)
    app.buttons["lorvex.visual.create.save"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func openWorkspace(_ app: XCUIApplication, language: TestLanguage) {
    let tasks = app.tabBars.buttons[language.tasks].firstMatch
    if tasks.waitForExistence(timeout: 15) { tasks.tap() }
    else {
      let adaptiveTasks = app.buttons[language.tasks].firstMatch
      XCTAssertTrue(adaptiveTasks.waitForExistence(timeout: 5))
      adaptiveTasks.tap()
    }
    let open = app.buttons["lorvex.visual.open"]
    XCTAssertTrue(open.waitForExistence(timeout: 15))
    open.tap()
    XCTAssertTrue(app.buttons["task-workspace.create"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.buttons["task-workspace.tab.graph"].label, language.modeTitle("graph"))
  }

  @MainActor
  private func selectMode(_ mode: String, app: XCUIApplication, language: TestLanguage) {
    let tab = app.buttons["task-workspace.tab." + mode]
    XCTAssertTrue(tab.waitForExistence(timeout: 10))
    let picker = app.scrollViews.containing(.button, identifier: "task-workspace.tab." + mode).firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    // XCTest can throw while hit-testing an offscreen accessibility element.
    // Use observed geometry first; physical scroll direction also works in RTL.
    for _ in 0..<5 {
      let viewport = picker.frame.intersection(app.frame)
      let buttonFrame = tab.frame
      if !viewport.isEmpty && !buttonFrame.isEmpty && viewport.contains(buttonFrame) {
        break
      }
      if buttonFrame.maxX > viewport.maxX {
        picker.swipeLeft()
      } else if buttonFrame.minX < viewport.minX {
        picker.swipeRight()
      } else {
        XCTFail("The mode strip must be visible before selecting \(mode): \(viewport), button \(buttonFrame).")
        return
      }
    }
    let viewport = picker.frame.intersection(app.frame)
    guard !viewport.isEmpty, !tab.frame.isEmpty, viewport.contains(tab.frame) else {
      XCTFail("The \(mode) tab did not enter the visible mode strip: \(viewport), button \(tab.frame).")
      return
    }
    XCTAssertTrue(tab.isHittable, "The \(mode) presentation must be reachable in \(language.rawValue).")
    tab.tap()
    expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: tab)
    waitForExpectations(timeout: 5)
    XCTAssertEqual(tab.label, language.modeTitle(mode))
    let surfaceID: String
    switch mode {
    case "graph": surfaceID = "task-workspace.graph.canvas"
    case "network": surfaceID = "task-workspace.network.canvas"
    default: surfaceID = "task-workspace." + mode
    }
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: surfaceID)
        .firstMatch.waitForExistence(timeout: 10),
      "The selected \(mode) must render its actual native content.")
  }

  @MainActor
  private func findTaskButton(named title: String, app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", title)
    ).firstMatch
  }

  @MainActor
  private func searchFor(_ title: String, app: XCUIApplication) {
    let search = app.textFields["task-workspace.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText(title + "\n")
  }

  @MainActor
  private func clearSearch(_ app: XCUIApplication, language: TestLanguage) {
    app.buttons[language.clearSearch].tap()
  }

  @MainActor
  private func attachHierarchy(_ app: XCUIApplication, _ name: String) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = name + " hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    attach(app, name)
  }

  @MainActor
  private func attach(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  private enum TestLanguage: String {
    case en, he

    var locale: String { self == .he ? "he_IL" : "en_US" }
    var tasks: String { self == .he ? "משימות" : "Tasks" }
    var openLane: String { self == .he ? "פתוחות" : "Open" }
    var inProgress: String { self == .he ? "בביצוע" : "In Progress" }
    var taskPrefix: String { self == .he ? "בדיקת משימה " : "Visual task " }
    var hanlinTaskPrefix: String { self == .he ? "נוצרה דרך Hanlin " : "Hanlin created " }
    var dragTargetPrefix: String { self == .he ? "יעד לגרירה " : "Drag destination " }
    var boardScrollPrefix: String { self == .he ? "גלילת לוח " : "Board scroll " }
    var prerequisitePrefix: String { self == .he ? "הכנה " : "Prepare " }
    var editConnections: String { self == .he ? "עריכת קשרים" : "Edit connections" }
    var removeConnection: String { self == .he ? "הסרת קשר" : "Remove connection" }
    var openTask: String { self == .he ? "פתיחת משימה" : "Open task" }
    var reopenTask: String { self == .he ? "פתיחת המשימה מחדש" : "Reopen task" }
    var clearSearch: String { self == .he ? "ניקוי חיפוש" : "Clear search" }
    var hasDueDate: String { self == .he ? "יש מועד יעד" : "Has due date" }
    var setDate: String { self == .he ? "קביעת תאריך" : "Set date" }

    func modeTitle(_ mode: String) -> String {
      switch (self, mode) {
      case (.he, "graph"): "זרימה"
      case (.he, "board"): "לוח"
      case (.he, "timeline"): "ציר זמן"
      case (.he, "network"): "קשרים"
      case (.he, "table"): "טבלה"
      case (_, "graph"): "Flow"
      case (_, "board"): "Board"
      case (_, "timeline"): "Timeline"
      case (_, "network"): "Connections"
      case (_, "table"): "Table"
      default: mode
      }
    }
  }
}
