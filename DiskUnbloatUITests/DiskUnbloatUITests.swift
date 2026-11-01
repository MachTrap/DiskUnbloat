import XCTest

@MainActor final class DiskUnbloatUITests: XCTestCase {
    private var app: XCUIApplication!
    private func launch() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }
    func testLaunchIsLocationOnlyAndOptionsAreAvailable() {
        launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["chooseLocation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.outlines["fileTable"].exists)
        XCTAssertFalse(app.textFields["searchFiles"].exists)
        app.buttons["scanOptions"].click()
        XCTAssertTrue(app.switches["Include hidden files"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["chooseLocation"].click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }
}

extension DiskUnbloatUITests {
    func testRussianLocationScreen() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState","YES","-AppleLanguages","(ru)","-AppleLocale","ru_RU"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["chooseLocation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Освободите место для нового.")).firstMatch.exists)
        XCTAssertFalse(app.textFields["searchFiles"].exists)
    }
}
