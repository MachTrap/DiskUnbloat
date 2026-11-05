import Foundation
import XCTest

extension DiskUnbloatUITests {
    func testMapDetailSliderKeepsTheFocusedFolderWhenClosed() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MapDisplay-" + UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Map Detail Folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let filename = "A long title with several words for the map detail control.txt"
        try Data(repeating: 1, count: 64 * 1024).write(to: folder.appendingPathComponent(filename))
        launch()
        defer { app.terminate() }
        scanGeneratedFixture(root)

        let map = app.descendants(matching: .any)["storageMap"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        let breadcrumb = app.buttons["Map Detail Folder"].firstMatch
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 5))
        let display = app.buttons["mapDisplay"]
        display.click()
        let slider = app.sliders["mapLabelDetail"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["Balanced"].waitForExistence(timeout: 3))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["Detailed"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(slider.waitForNonExistence(timeout: 3))
        XCTAssertTrue(breadcrumb.exists)
        XCTAssertTrue(display.isHittable)
    }
}
