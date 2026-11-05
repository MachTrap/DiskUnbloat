import XCTest

@MainActor final class DiskUnbloatUITests: XCTestCase {
    var app: XCUIApplication!
    func launch(language: String = "en", locale: String = "en_US") {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
    }

    func scanGeneratedFixture(_ root: URL) {
        let choose = app.buttons["chooseLocation"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        let picker = app.dialogs.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(root.path)
        app.typeKey(.return, modifierFlags: [])
        let accept = picker.buttons["Choose location"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.click()
        let queue = app.descendants(matching: .any).matching(identifier: "cleanupQueue").firstMatch
        if !queue.exists {
            let withoutFullDiskAccess = app.buttons["Continue without it"]
            if withoutFullDiskAccess.waitForExistence(timeout: 3) { withoutFullDiskAccess.click() }
        }
        XCTAssertTrue(queue.waitForExistence(timeout: 10))
    }
    func testLaunchIsLocationOnlyAndOptionsAreAvailable() {
        launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["chooseLocation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.outlines["fileTable"].exists)
        XCTAssertFalse(app.textFields["searchFiles"].exists)
        // The cleanup queue belongs to results; it must not mount before a scan.
        XCTAssertFalse(app.descendants(matching: .any)["cleanupQueue"].exists)
        app.buttons["scanOptions"].click()
        XCTAssertTrue(app.switches["Include hidden files"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["chooseLocation"].click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }
}

extension DiskUnbloatUITests {
    func testDuplicateReviewQueuesOnlyCheckedCopiesAndEscapeLeavesQueueIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloat-UI-Duplicates-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 45, count: 1_500_000)
        for (index, relativePath) in ["First/Original.bin", "Second/Copy B.bin", "Third/Copy C.bin"].enumerated() {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))], ofItemAtPath: url.path)
        }
        launch()
        defer { app.terminate() }
        scanGeneratedFixture(root)

        let quickSelect = app.popUpButtons["selectionLevel"]
        XCTAssertTrue(quickSelect.waitForExistence(timeout: 5))
        quickSelect.click()
        app.menuItems["Duplicate files"].click()
        app.buttons["findDuplicates"].click()
        let review = app.descendants(matching: .any).matching(identifier: "duplicateReview").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.textFields["duplicateReviewSearch"].exists)
        let copies = review.checkBoxes.matching(identifier: "duplicateReviewCopy")
        XCTAssertEqual(copies.count, 3)
        let confirm = review.buttons["duplicateReviewConfirm"]
        XCTAssertFalse(confirm.isEnabled)
        let candidate = try XCTUnwrap(copies.allElementsBoundByIndex.first(where: { $0.isEnabled }))
        candidate.click()

        let filter = review.popUpButtons["duplicateReviewKind"]
        filter.click()
        app.menuItems["Selected"].click()
        XCTAssertTrue(confirm.isEnabled)
        confirm.click()
        XCTAssertTrue(review.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 item"].waitForExistence(timeout: 5))

        app.buttons["selectDuplicates"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(review.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 item"].exists)
    }

    func testRussianLocationScreen() {
        launch(language: "ru", locale: "ru_RU"); defer { app.terminate() }
        XCTAssertTrue(app.buttons["chooseLocation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Освободите место для нового.")).firstMatch.exists)
        XCTAssertFalse(app.textFields["searchFiles"].exists)
    }
}
