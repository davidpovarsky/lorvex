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
    func testHebrewCloudAndChatGPTSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-setupCompleted", "YES", "-AppleLanguages", "(he)", "-AppleLocale", "he_IL"]
        app.launch()
        let open = app.buttons["hanlin.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        let cancel = app.buttons["hanlin.model.cancel"]
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
        let close = app.buttons["hanlin.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertEqual(close.label, "סגירה")
        let nav = app.navigationBars["Hanlin AI"]
        XCTAssertGreaterThan(close.frame.midX, nav.frame.midX, "Hebrew cancellation control must follow RTL navigation")
        app.buttons["hanlin.cloud.settings"].tap()
        XCTAssertTrue(app.navigationBars["ענן Lorvex"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["lorvex.cloud.sign-in"].exists)
        XCTAssertEqual(app.buttons["lorvex.cloud.sign-in"].label, "התחברות")
        XCTAssertTrue(app.textFields["lorvex.cloud.email"].exists)
        XCTAssertTrue(app.secureTextFields["lorvex.cloud.password"].exists)
        attach(app, "Lorvex - Hebrew RTL cloud account")
        app.buttons["סיום"].tap()
        app.buttons["hanlin.model.settings"].tap()
        XCTAssertTrue(app.navigationBars["הגדרות מודל Hanlin"].waitForExistence(timeout: 5))
        attach(app, "Lorvex - Hebrew provider settings")
        let provider = app.buttons["hanlin.model.provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
        let chatGPT = app.buttons["חשבון ChatGPT"]
        XCTAssertTrue(chatGPT.waitForExistence(timeout: 5))
        chatGPT.tap()
        let manage = app.buttons["hanlin.chatgpt.settings"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        XCTAssertTrue(app.navigationBars["חשבון ChatGPT"].waitForExistence(timeout: 5))
        let add = app.buttons["chatgpt.accounts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable)
        attach(app, "Lorvex - Hebrew ChatGPT account management")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
