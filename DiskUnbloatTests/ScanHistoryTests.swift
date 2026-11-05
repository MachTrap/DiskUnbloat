import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// A finished scan leaves sizes (never contents) for its scope; the next scan of the same
/// scope colours growth against it, and history can be turned off or cleared.
@MainActor struct ScanHistoryTests {
    private func store() -> ScanHistoryStore {
        ScanHistoryStore(base: FileManager.default.temporaryDirectory.appendingPathComponent("history-" + UUID().uuidString), keep: 3)
    }
    private func write(_ root: URL, _ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0) }).write(to: url)
    }

    @Test func storeKeepsTheNewestSnapshotsPerScopeAndClears() throws {
        let history = store()
        for day in 1...5 {
            try history.save(ScanHistorySnapshot(rootKey: "/a", date: Date(timeIntervalSince1970: Double(day) * 86_400), totalBytes: 1, sizes: [:], minimumBytes: 1, partial: false))
        }
        try history.save(ScanHistorySnapshot(rootKey: "/b", date: Date(timeIntervalSince1970: 1), totalBytes: 1, sizes: ["/b/x": 5], minimumBytes: 1, partial: false))
        #expect(history.dates(rootKey: "/a").map { Int($0.timeIntervalSince1970 / 86_400) } == [5, 4, 3])
        #expect(history.load(rootKey: "/b", date: Date(timeIntervalSince1970: 1))?.sizes == ["/b/x": 5])
        history.clear()
        #expect(history.dates(rootKey: "/a").isEmpty && history.dates(rootKey: "/b").isEmpty)
    }

    @Test func secondScanColoursGrowthAgainstTheFirst() async throws {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("growth-" + UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "Grows/a.bin", 2 << 20)
        try write(root, "Same/b.bin", 2 << 20)
        let history = store()
        let model = WorkspaceViewModel(settings: SettingsViewModel(defaults: isolatedDefaults(), history: history),
                                       fullDiskAccess: GrantedFullDiskAccess(), defaults: isolatedDefaults())
        model.explorer.colorMode = .growth
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        // First scan: nothing to compare with yet.
        #expect(model.explorer.historyDates.isEmpty)
        #expect(Set(model.explorer.tileStyle.classes.values) == [.noHistory])
        for _ in 0..<100 where history.dates(rootKey: ScanHistorySnapshot.rootKey([root])).isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        try write(root, "Grows/c.bin", 6 << 20)
        try write(root, "New/d.bin", 3 << 20)
        model.startScan(); await model.waitForScan()
        #expect(model.explorer.historyDates.count == 1)
        func tileClass(_ name: String) -> TileClass? {
            model.explorer.scene.entries.first { $0.node?.name == name }.flatMap { model.explorer.tileStyle.classes[$0.id] }
        }
        #expect(tileClass("Grows") == .grew)
        #expect(tileClass("Same") == .unchanged)
        #expect(tileClass("New") == .added)
        let grows = try #require(model.explorer.scene.entries.first { $0.node?.name == "Grows" })
        #expect(model.explorer.growthNote(for: grows)?.hasPrefix("+") == true)
        await model.shutdown()
    }

    @Test func turnedOffHistoryRecordsNothing() async throws {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("nohistory-" + UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.bin", 2 << 20)
        let history = store()
        let settings = SettingsViewModel(defaults: isolatedDefaults(), history: history)
        settings.keepScanHistory = false
        let model = WorkspaceViewModel(settings: settings, fullDiskAccess: GrantedFullDiskAccess(), defaults: isolatedDefaults())
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        try await Task.sleep(for: .milliseconds(200))
        #expect(history.dates(rootKey: ScanHistorySnapshot.rootKey([root])).isEmpty)
        await model.shutdown()
    }
}
