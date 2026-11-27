import XCTest
final class ControlDragCalibrationTests: XCTestCase {
    @MainActor func testString0800ms() throws { try run(kind: "string", hold: 0.8) }
    @MainActor func testString1500ms() throws { try run(kind: "string", hold: 1.5) }
    @MainActor func testCodable0800ms() throws { try run(kind: "codable", hold: 0.8) }
    @MainActor func testCodable1500ms() throws { try run(kind: "codable", hold: 1.5) }
    @MainActor private func run(kind: String, hold: TimeInterval) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(he)", "-AppleLocale", "he_IL"]
        app.launchEnvironment["CALIBRATION_KIND"] = kind
        app.launch()
        let source = app.descendants(matching: .any).matching(identifier: "calibration.source").firstMatch
        let destination = app.descendants(matching: .any).matching(identifier: "calibration.destination").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertEqual(source.frame.minX, 21, accuracy: 1)
        XCTAssertEqual(source.frame.minY, 407.333333, accuracy: 1)
        XCTAssertEqual(destination.frame.minX, 317, accuracy: 1)
        let visible = destination.frame.intersection(app.frame)
        XCTAssertGreaterThanOrEqual(visible.width, 44)
        let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = destination.coordinate(withNormalizedOffset: CGVector(
            dx: (visible.midX - destination.frame.minX) / destination.frame.width,
            dy: (visible.midY - destination.frame.minY) / destination.frame.height))
        let input = XCTAttachment(string: "diagnosticOnly=true kind=\(kind) hold=\(hold) from=\(from.screenPoint) to=\(to.screenPoint)")
        input.name = "Native control calibration input"
        input.lifetime = .keepAlways
        add(input)
        from.press(forDuration: hold, thenDragTo: to)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Native control calibration after drag"
        after.lifetime = .keepAlways
        add(after)
        let result = app.staticTexts["calibration.result"]
        expectation(for: NSPredicate(format: "label == %@", "dropped"), evaluatedWith: result)
        waitForExpectations(timeout: 10)
    }
}
