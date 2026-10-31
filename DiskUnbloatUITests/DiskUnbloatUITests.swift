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
    private func loadSample() {
        app.buttons["loadSample"].click()
        XCTAssertTrue(app.buttons["toggleFiles"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.outlines["fileTable"].exists)
    }
    func testMapDefaultsAndOptionalFileDrawer() {
        launch(); defer { app.terminate() }
        loadSample()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.outlines["fileTable"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertFalse(app.outlines["fileTable"].exists)
    }
    func testDrillDownAndScopedSearch() {
        launch(); defer { app.terminate() }
        loadSample()
        app.buttons["toggleFiles"].click()
        let creative = app.outlines.staticTexts["Creative"].firstMatch
        XCTAssertTrue(creative.waitForExistence(timeout: 5)); creative.doubleClick()
        XCTAssertTrue(app.outlines.staticTexts["Film edit.mov"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        app.textFields["searchFiles"].typeText("Film")
        XCTAssertTrue(app.outlines.staticTexts["Film edit.mov"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.outlines.staticTexts["Archive.zip"].exists)
    }
    func testCleanupConfirmationsCanBeCancelled() {
        launch(); defer { app.terminate() }
        loadSample()
        app.buttons["toggleFiles"].click()
        app.outlines.staticTexts["Creative"].firstMatch.click()
        app.buttons["addToReview"].click()
        app.buttons["reviewCleanup"].click()
        XCTAssertTrue(app.buttons["permanentDelete"].waitForExistence(timeout: 5))
        app.buttons["permanentDelete"].click()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].click()
        app.buttons["moveToTrash"].click()
        XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }
}

extension DiskUnbloatUITests {
    func testAnalysisTabsAndFolderRefresh() {
        launch(); defer { app.terminate() }
        loadSample(); app.typeKey("2",modifierFlags: .command)
        let tabs = app.descendants(matching: .any)["analysisTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Largest")).firstMatch.click()
        XCTAssertTrue(app.outlines.staticTexts["Film edit.mov"].firstMatch.waitForExistence(timeout: 5))
        tabs.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Types")).firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["categoryStatistics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Video")).firstMatch.exists)
        tabs.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Candidates")).firstMatch.click()
        XCTAssertTrue(app.popUpButtons.firstMatch.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Scan"].click()
        app.menuItems["Rescan Folder"].click()
        XCTAssertTrue(app.buttons["toggleFiles"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["analysisTabs"].exists)
    }

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
