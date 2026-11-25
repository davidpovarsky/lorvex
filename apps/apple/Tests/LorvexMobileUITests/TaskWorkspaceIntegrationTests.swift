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
    var boardDragVerified = false
    if UIDevice.current.userInterfaceIdiom == .pad {
      clearSearch(app, language: language)
      let destinationTitle = language.dragTargetPrefix + String(UUID().uuidString.prefix(8))
      createTask(app, title: destinationTitle)
      let destinationRow = findTaskButton(named: destinationTitle, app: app)
      XCTAssertTrue(destinationRow.waitForExistence(timeout: 10))
      let destinationID = String(destinationRow.identifier.dropFirst("task-workspace.open.".count))
      selectMode("board", app: app, language: language)
      let sourceCard = app.buttons["task-workspace.open." + taskID]
      let destinationCard = app.buttons["task-workspace.open." + destinationID]
      XCTAssertTrue(sourceCard.waitForExistence(timeout: 10))
      XCTAssertTrue(destinationCard.waitForExistence(timeout: 10))
      XCTAssertTrue(app.frame.contains(sourceCard.frame) && app.frame.contains(destinationCard.frame))
      XCTAssertTrue(sourceCard.isHittable && destinationCard.isHittable)
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "Lorvex \(language.rawValue) - native board before drag"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      attach(app, "Lorvex \(language.rawValue) - adjacent canonical board columns before drag")
      // AdvancedKanban owns a native DragGesture. A short touch followed by
      // movement exercises onMove without opening the card context menu.
      sourceCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        .press(forDuration: 0.05, thenDragTo:
          destinationCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
      selectMode("table", app: app, language: language)
      searchFor(title, app: app)
      expectation(for: NSPredicate(format: "label == %@", language.openLane), evaluatedWith: lane)
      waitForExpectations(timeout: 10)
      boardDragVerified = true
      attach(app, "Lorvex \(language.rawValue) - table confirms native board drag saved Open")
    } else {
      selectMode("board", app: app, language: language)
      XCTAssertTrue(app.buttons["task-workspace.open." + taskID].waitForExistence(timeout: 10))
      attach(app, "Lorvex \(language.rawValue) - board reflects canonical In Progress transition")
      selectMode("table", app: app, language: language)
    }
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
      "nativeBoardDragVerified": boardDragVerified,
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
    XCTAssertTrue(assistant.isHittable && app.frame.contains(assistant.frame))
    let assistantFrame = assistant.frame
    let controls = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "task-workspace.")
    ).allElementsBoundByIndex.filter {
      $0.exists && !$0.frame.isEmpty && app.frame.intersects($0.frame)
    }
    XCTAssertFalse(controls.isEmpty)
    let frames = controls.map { "\($0.identifier)=\($0.frame)" }
    let observation = XCTAttachment(string: "hanlin=\(assistantFrame)\n" + frames.joined(separator: "\n"))
    observation.name = "Lorvex \(language.rawValue) - \(mode) assistant and workspace control frames"
    observation.lifetime = .keepAlways
    add(observation)
    for control in controls {
      XCTAssertFalse(
        assistantFrame.intersects(control.frame),
        "The Hanlin entry must not cover \(control.identifier).")
    }
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
    var prerequisitePrefix: String { self == .he ? "הכנה " : "Prepare " }
    var editConnections: String { self == .he ? "עריכת קשרים" : "Edit connections" }
    var removeConnection: String { self == .he ? "הסרת קשר" : "Remove connection" }
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
