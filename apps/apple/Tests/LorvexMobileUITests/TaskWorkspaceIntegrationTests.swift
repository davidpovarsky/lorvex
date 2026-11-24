import XCTest

/// Writes through the shipped workspace, checks the original task detail and
/// relaunches the app. These are real local test tasks in the test simulator.
final class TaskWorkspaceIntegrationTests: XCTestCase {
  @MainActor
  func testVisualTaskCompletionSurvivesRelaunch() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-setupCompleted", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    openWorkspace(app)
    let title = "Visual task " + String(UUID().uuidString.prefix(8))
    let prerequisite = "Prepare " + String(UUID().uuidString.prefix(8))
    createTask(app, title: title)
    createTask(app, title: prerequisite)
    app.buttons["task-workspace.options"].tap()
    app.buttons["Edit connections"].tap()
    let prerequisitePicker = app.buttons["task-workspace.connection.prerequisite"]
    XCTAssertTrue(prerequisitePicker.waitForExistence(timeout: 5))
    prerequisitePicker.tap()
    app.buttons[prerequisite].tap()
    app.buttons["task-workspace.connection.dependent"].tap()
    app.buttons[title].tap()
    let connect = app.buttons["task-workspace.connection.add"]
    XCTAssertTrue(connect.isEnabled)
    connect.tap()
    let done = app.buttons["task-workspace.connection.done"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done)
    waitForExpectations(timeout: 10)
    done.tap()
    XCTAssertTrue(app.buttons["task-workspace.tab.graph"].waitForExistence(timeout: 5))
    attach(app, "Lorvex - two real tasks connected in the native graph")

    let table = app.buttons["task-workspace.tab.table"]
    XCTAssertTrue(table.waitForExistence(timeout: 10))
    if !table.isHittable { app.buttons["task-workspace.tab.graph"].swipeLeft() }
    table.tap()
    let search = app.textFields["task-workspace.search"]
    search.tap()
    search.typeText(prerequisite)
    let prerequisiteButton = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", prerequisite)
    ).firstMatch
    XCTAssertTrue(prerequisiteButton.waitForExistence(timeout: 10))
    let prerequisiteID = String(prerequisiteButton.identifier.dropFirst("task-workspace.open.".count))
    let prerequisiteComplete = app.buttons["task-workspace.complete." + prerequisiteID]
    prerequisiteComplete.tap()
    expectation(for: NSPredicate(format: "label == %@", "Reopen task"), evaluatedWith: prerequisiteComplete)
    waitForExpectations(timeout: 10)
    app.buttons["Clear search"].tap()
    search.tap()
    search.typeText(title)
    let taskButton = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", title)
    ).firstMatch
    XCTAssertTrue(taskButton.waitForExistence(timeout: 10))
    let taskID = String(taskButton.identifier.dropFirst("task-workspace.open.".count))
    attach(app, "Lorvex - live visual task table")
    let complete = app.buttons["task-workspace.complete." + taskID]
    XCTAssertTrue(complete.isHittable)
    complete.tap()
    let reopenedLabel = NSPredicate(format: "label == %@", "Reopen task")
    expectation(for: reopenedLabel, evaluatedWith: complete)
    waitForExpectations(timeout: 10)
    taskButton.tap()
    let reopen = app.buttons["task.detail.reopen"]
    XCTAssertTrue(reopen.waitForExistence(timeout: 10))
    attach(app, "Lorvex - original task detail reflects workspace completion")
    app.buttons["lorvex.visual.detail.close"].tap()

    app.terminate()
    app.launch()
    openWorkspace(app)
    let tableAgain = app.buttons["task-workspace.tab.table"]
    if !tableAgain.isHittable { app.buttons["task-workspace.tab.graph"].swipeLeft() }
    tableAgain.tap()
    let searchAgain = app.textFields["task-workspace.search"]
    searchAgain.tap()
    searchAgain.typeText(title)
    let persisted = app.buttons["task-workspace.open." + taskID]
    XCTAssertTrue(persisted.waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["task-workspace.complete." + taskID].label, "Reopen task")
    persisted.tap()
    XCTAssertTrue(app.buttons["task.detail.reopen"].waitForExistence(timeout: 10))
    app.buttons["task.detail.reopen"].tap()
    XCTAssertTrue(app.buttons["task.detail.complete"].waitForExistence(timeout: 10))
    attach(app, "Lorvex - persisted task reopened through original editor")
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
  private func openWorkspace(_ app: XCUIApplication) {
    let tasks = app.tabBars.buttons["Tasks"].firstMatch
    if tasks.waitForExistence(timeout: 15) { tasks.tap() }
    else { app.buttons["Tasks"].firstMatch.tap() }
    let open = app.buttons["lorvex.visual.open"]
    XCTAssertTrue(open.waitForExistence(timeout: 15))
    open.tap()
    XCTAssertTrue(app.buttons["task-workspace.create"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func attach(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
