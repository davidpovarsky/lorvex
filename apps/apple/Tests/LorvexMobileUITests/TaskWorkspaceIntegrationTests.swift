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
    let app = XCUIApplication()
    app.launchArguments = [
      "-setupCompleted", "YES", "-AppleLanguages", "(\(language.rawValue))",
      "-AppleLocale", language.locale,
    ]
    app.launchEnvironment["LORVEX_CLOUD_SYNC"] = "off"
    app.launch()
    openWorkspace(app, language: language)
    let title = language.taskPrefix + String(UUID().uuidString.prefix(8))
    let prerequisite = language.prerequisitePrefix + String(UUID().uuidString.prefix(8))
    createTask(app, title: title)
    createTask(app, title: prerequisite)

    app.buttons["task-workspace.options"].tap()
    app.buttons[language.editConnections].tap()
    let prerequisitePicker = app.buttons["task-workspace.connection.prerequisite"]
    XCTAssertTrue(prerequisitePicker.waitForExistence(timeout: 5))
    prerequisitePicker.tap()
    app.buttons[prerequisite].tap()
    app.buttons["task-workspace.connection.dependent"].tap()
    app.buttons[title].tap()
    let connect = app.buttons["task-workspace.connection.add"]
    XCTAssertTrue(connect.isEnabled)
    connect.tap()
    XCTAssertTrue(
      app.buttons[language.removeConnection].firstMatch.waitForExistence(timeout: 10),
      "The real saved dependency must appear in the connection editor.")
    let remove = app.buttons[language.removeConnection].firstMatch
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

    // Schedule a real task so the timeline assertion exercises an actual chart,
    // as well as the date patch and its persistence, rather than an empty state.
    let dueDate = app.buttons["task-workspace.date." + taskID]
    XCTAssertTrue(dueDate.isHittable)
    dueDate.tap()
    let hasDueDate = app.switches[language.hasDueDate]
    XCTAssertTrue(hasDueDate.waitForExistence(timeout: 5))
    XCTAssertEqual(hasDueDate.value as? String, "0")
    hasDueDate.tap()
    let saveDate = app.buttons["task-workspace.date.save"]
    saveDate.tap()
    XCTAssertTrue(saveDate.waitForNonExistence(timeout: 10))
    XCTAssertNotEqual(dueDate.label, language.setDate)
    let savedDateLabel = dueDate.label
    clearSearch(app, language: language)

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
        dateToggle.tap()
        app.buttons["task-workspace.date.save"].tap()
        XCTAssertTrue(dateToggle.waitForNonExistence(timeout: 10))
        XCTAssertTrue(timelineDetail.waitForExistence(timeout: 10))
        attach(app, "Lorvex \(language.rawValue) - timeline inspector writes the planned date")
        app.buttons["task-workspace.timeline.close-actions"].tap()
      }
      if mode == "network" || mode == "graph" {
        let node = mode == "network"
          ? app.buttons[title].firstMatch
          : app.buttons["task-workspace.open." + taskID]
        XCTAssertTrue(
          node.waitForExistence(timeout: 10),
          "The native graph must expose the real task as an accessible node.")
        node.tap()
        XCTAssertTrue(app.buttons["task.detail.complete"].waitForExistence(timeout: 10))
        app.buttons["lorvex.visual.detail.close"].tap()
        XCTAssertTrue(app.buttons["task-workspace.tab." + mode].waitForExistence(timeout: 10))
      }
      attach(app, "Lorvex \(language.rawValue) - live \(mode) with connected real tasks")
    }

    searchFor(prerequisite, app: app)
    let prerequisiteButton = findTaskButton(named: prerequisite, app: app)
    XCTAssertTrue(prerequisiteButton.waitForExistence(timeout: 10))
    let prerequisiteID = String(prerequisiteButton.identifier.dropFirst("task-workspace.open.".count))
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
      "nativeBoardDragVerified": boardDragVerified,
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
