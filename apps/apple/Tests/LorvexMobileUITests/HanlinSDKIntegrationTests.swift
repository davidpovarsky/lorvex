import XCTest

/// One real-host acceptance path. The existing agent tests cover native tool
/// execution/consent; this test mounts the SDK in the shipping Lorvex app.
final class HanlinSDKIntegrationTests: XCTestCase {
    @MainActor
    func testOriginalComposerInsideLorvex() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-setupCompleted", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let open = app.buttons["hanlin.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        let settings = app.navigationBars["Hanlin model settings"]
        if settings.waitForExistence(timeout: 3) { settings.buttons["Cancel"].tap() }
        let editor = app.textViews["hanlin-chat-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.isHittable)
        attach(app, "Lorvex - original Hanlin Composer")

        editor.tap()
        editor.typeText("Plan this week\nKeep time for reading and rest.")
        XCTAssertTrue((editor.value as? String)?.contains("Keep time for reading") == true)
        XCTAssertTrue(app.buttons["hanlin.composer.send"].isEnabled)
        attach(app, "Lorvex - native multiline draft and keyboard")

        let menu = app.buttons["hanlin-composer-general-menu"]
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        let tools = app.buttons["hanlin.composer.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        tools.tap()
        XCTAssertTrue(app.otherElements["hanlin.composer.toolCatalog"].waitForExistence(timeout: 5))
        attach(app, "Lorvex - original Morph panel and real host tools")
        app.buttons["composer-toolbar-close"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("Plan this week") == true)
        app.buttons["hanlin.close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        if settings.waitForExistence(timeout: 2) { settings.buttons["Cancel"].tap() }
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.isHittable)
        attach(app, "Lorvex - reopened actual assistant")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
