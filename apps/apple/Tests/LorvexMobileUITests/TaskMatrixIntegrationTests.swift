import UIKit
import XCTest

/// Supplemental real native acceptance. The original five-view workspace
/// method is retained and runs separately on every device/language case.
final class TaskMatrixIntegrationTests: XCTestCase {
  @MainActor
  func testMatrixCanonicalEditsAndCancellationSurviveRelaunch() throws {
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
    let title = language.taskPrefix + String(UUID().uuidString.prefix(8))
    let prerequisiteTitle = language.prerequisitePrefix + String(UUID().uuidString.prefix(8))
    createTask(app, title: title)
    createTask(app, title: prerequisiteTitle)
    let task = app.buttons.matching(NSPredicate(
      format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", title)).firstMatch
    let prerequisite = app.buttons.matching(NSPredicate(
      format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", prerequisiteTitle)).firstMatch
    XCTAssertTrue(task.waitForExistence(timeout: 10))
    XCTAssertTrue(prerequisite.waitForExistence(timeout: 10))
    let id = String(task.identifier.dropFirst("task-workspace.open.".count))
    let prerequisiteID = String(prerequisite.identifier.dropFirst("task-workspace.open.".count))
    XCTAssertFalse(id.isEmpty)
    XCTAssertNotEqual(id, prerequisiteID)
    app.buttons["task-workspace.options"].tap()
    app.buttons[language.editConnections].tap()
    app.buttons["task-workspace.connection.prerequisite"].tap()
    selectConnection(prerequisiteTitle, app: app)
    app.buttons["task-workspace.connection.dependent"].tap()
    selectConnection(title, app: app)
    app.buttons["task-workspace.connection.add"].tap()
    XCTAssertTrue(app.buttons[language.removeConnection].waitForExistence(timeout: 10))
    app.buttons["task-workspace.connection.done"].tap()

    openMatrix(app, language: language)
    search(title, app: app)
    assertMembership(id, quadrant: "normalLater", app: app)
    setPriority(language.highPriority, id: id, app: app)
    assertMembership(id, quadrant: "highLater", app: app)
    editDay("due", id: id, offset: 0, save: true, app: app, language: language)
    assertMembership(id, quadrant: "highDue", app: app)
    editDay("planned", id: id, offset: 1, save: true, app: app, language: language)
    assertMembership(id, quadrant: "highDue", app: app)
    let due = app.buttons["lorvex.matrix.due." + id]
    let planned = app.buttons["lorvex.matrix.planned." + id]
    let savedDue = due.label
    let savedPlanned = planned.label
    XCTAssertNotEqual(savedDue, savedPlanned)
    let dependency = app.descendants(matching: .any)
      .matching(identifier: "lorvex.matrix.dependencies." + id).firstMatch
    XCTAssertTrue(dependency.exists)
    capture(app, "Lorvex Matrix \(language.rawValue) - priority deadline and independent planned day")

    editDay("due", id: id, offset: 1, save: false, app: app, language: language)
    XCTAssertEqual(due.label, savedDue)
    XCTAssertEqual(planned.label, savedPlanned)
    assertMembership(id, quadrant: "highDue", app: app)
    setPriority(language.normalPriority, id: id, app: app)
    assertMembership(id, quadrant: "normalDue", app: app)
    XCTAssertEqual(due.label, savedDue)
    XCTAssertEqual(planned.label, savedPlanned)
    setPriority(language.highPriority, id: id, app: app)
    assertMembership(id, quadrant: "highDue", app: app)

    let open = app.buttons["lorvex.matrix.open." + id]
    tapVisible(open, app: app)
    XCTAssertTrue(app.buttons["task.detail.complete"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["task.detail.row.due"].exists)
    XCTAssertEqual(app.staticTexts["task.detail.title"].label, title)
    capture(app, "Lorvex Matrix \(language.rawValue) - original task detail")
    app.buttons["task.detail.complete"].tap()
    XCTAssertTrue(app.buttons["task.detail.reopen"].waitForExistence(timeout: 10))
    app.buttons["lorvex.visual.detail.close"].tap()
    let complete = app.buttons["lorvex.matrix.complete." + id]
    expectation(for: NSPredicate(format: "label == %@", language.reopen), evaluatedWith: complete)
    waitForExpectations(timeout: 10)
    XCTAssertEqual(due.label, savedDue)
    XCTAssertEqual(planned.label, savedPlanned)

    app.terminate()
    app.launch()
    openWorkspace(app, language: language)
    openMatrix(app, language: language)
    search(title, app: app)
    assertMembership(id, quadrant: "highDue", app: app)
    XCTAssertEqual(app.buttons["lorvex.matrix.priority." + id].label, language.highPriority)
    XCTAssertEqual(app.buttons["lorvex.matrix.due." + id].label, savedDue)
    XCTAssertEqual(app.buttons["lorvex.matrix.planned." + id].label, savedPlanned)
    XCTAssertTrue(app.descendants(matching: .any)
      .matching(identifier: "lorvex.matrix.dependencies." + id).firstMatch.exists)
    let reopen = app.buttons["lorvex.matrix.complete." + id]
    XCTAssertEqual(reopen.label, language.reopen)
    tapVisible(reopen, app: app)
    expectation(for: NSPredicate(format: "label == %@", language.complete), evaluatedWith: reopen)
    waitForExpectations(timeout: 10)
    tapVisible(app.buttons["lorvex.matrix.open." + id], app: app)
    XCTAssertTrue(app.buttons["task.detail.complete"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["task.detail.title"].label, title)
    app.buttons["lorvex.visual.detail.close"].tap()
    capture(app, "Lorvex Matrix \(language.rawValue) - persisted task reopened")
    let proof: [String: Any] = [
      "sourceSHA": ProcessInfo.processInfo.environment["LORVEX_TEST_SOURCE_SHA"] ?? "unrecorded",
      "language": language.rawValue, "family": UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
      "taskID": id, "prerequisiteID": prerequisiteID,
      "quadrantsObserved": ["normalLater", "highLater", "highDue", "normalDue"],
      "canonicalTaskDetailVerified": true, "independentDatesVerified": true,
      "cancelPreservedDueDate": true, "priorityChangesPreservedDates": true,
      "dependencySurvivedRestart": true, "completedStateSurvivedRestart": true,
      "reopenedCanonicalTask": true, "sourceScreenshotsCaptured": true
    ]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]),
      uniformTypeIdentifier: "public.json")
    attachment.name = "Lorvex Matrix acceptance proof"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func openWorkspace(_ app: XCUIApplication, language: Language) {
    let tab = app.tabBars.buttons[language.tasks].firstMatch
    if tab.waitForExistence(timeout: 15) { tab.tap() }
    else {
      let button = app.buttons[language.tasks].firstMatch
      XCTAssertTrue(button.waitForExistence(timeout: 5))
      button.tap()
    }
    let open = app.buttons["lorvex.visual.open"]
    XCTAssertTrue(open.waitForExistence(timeout: 15))
    open.tap()
    XCTAssertTrue(app.buttons["task-workspace.create"].waitForExistence(timeout: 15))
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
  private func selectConnection(_ title: String, app: XCUIApplication) {
    let choice = app.collectionViews.buttons[title]
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    XCTAssertTrue(choice.isHittable)
    choice.tap()
  }

  @MainActor
  private func openMatrix(_ app: XCUIApplication, language: Language) {
    let picker = app.segmentedControls["lorvex.visual.presentation"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    picker.buttons[language.matrix].tap()
    XCTAssertTrue(app.textFields["lorvex.matrix.search"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func search(_ title: String, app: XCUIApplication) {
    let field = app.textFields["lorvex.matrix.search"]
    field.tap()
    field.typeText(title + "\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
  }

  @MainActor
  private func assertMembership(_ id: String, quadrant: String, app: XCUIApplication) {
    reveal(app.buttons["lorvex.matrix.open." + id], app: app)
    let container = app.descendants(matching: .any)
      .matching(identifier: "lorvex.matrix.quadrant." + quadrant).firstMatch
    XCTAssertTrue(container.waitForExistence(timeout: 10))
    XCTAssertTrue(container.buttons["lorvex.matrix.open." + id].waitForExistence(timeout: 10))
  }

  @MainActor
  private func setPriority(_ label: String, id: String, app: XCUIApplication) {
    tapVisible(app.buttons["lorvex.matrix.priority." + id], app: app)
    let option = app.collectionViews.staticTexts[label].firstMatch
    XCTAssertTrue(option.waitForExistence(timeout: 5))
    option.tap()
    let done = app.buttons["task.field.done"]
    XCTAssertTrue(done.isEnabled)
    done.tap()
    XCTAssertTrue(done.waitForNonExistence(timeout: 10))
    XCTAssertEqual(app.buttons["lorvex.matrix.priority." + id].label, label)
  }

  @MainActor
  private func editDay(_ field: String, id: String, offset: Int, save: Bool,
    app: XCUIApplication, language: Language) {
    tapVisible(app.buttons["lorvex.matrix." + field + "." + id], app: app)
    let quickDay = app.buttons["task.field.day.\(offset)"]
    XCTAssertTrue(quickDay.waitForExistence(timeout: 5))
    quickDay.tap()
    let done = app.buttons["task.field.done"]
    if save { done.tap() }
    else { app.buttons[language.cancel].firstMatch.tap() }
    XCTAssertTrue(done.waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func tapVisible(_ element: XCUIElement, app: XCUIApplication) {
    reveal(element, app: app)
    XCTAssertTrue(element.isHittable)
    element.tap()
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    let scroll = app.scrollViews["lorvex.matrix.scroll"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 10))
    for _ in 0..<8 {
      let viewport = scroll.frame.intersection(app.frame)
      if element.exists {
        let frame = element.frame
        if !frame.isEmpty, viewport.contains(frame), element.isHittable { return }
        if !frame.isEmpty, frame.minY < viewport.minY { scroll.swipeDown() }
        else { scroll.swipeUp() }
      } else { scroll.swipeUp() }
    }
    XCTAssertTrue(element.exists, "The real Matrix task control must enter the scroll view.")
    XCTAssertTrue(scroll.frame.intersection(app.frame).contains(element.frame))
  }

  @MainActor
  private func capture(_ app: XCUIApplication, _ name: String) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = name + " hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  private enum Language: String {
    case en, he
    var locale: String { self == .he ? "he_IL" : "en_US" }
    var tasks: String { self == .he ? "משימות" : "Tasks" }
    var matrix: String { self == .he ? "מטריצה" : "Matrix" }
    var taskPrefix: String { self == .he ? "בדיקת מטריצה " : "Matrix task " }
    var prerequisitePrefix: String { self == .he ? "הכנה למטריצה " : "Matrix preparation " }
    var highPriority: String { self == .he ? "עדיפות גבוהה" : "High priority" }
    var normalPriority: String { self == .he ? "עדיפות רגילה" : "Normal priority" }
    var editConnections: String { self == .he ? "עריכת קשרים" : "Edit connections" }
    var removeConnection: String { self == .he ? "הסרת קשר" : "Remove connection" }
    var complete: String { self == .he ? "השלמה" : "Complete" }
    var reopen: String { self == .he ? "פתיחה מחדש" : "Reopen" }
    var cancel: String { self == .he ? "ביטול" : "Cancel" }
  }
}
