import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct PresentationTests {
    private func index(name: String) async throws -> ScanIndex {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let index = try ScanIndex(url: url)
        let root = "/fixture/" + name
        try await index.insert([
            FileNode(id: 1, parentID: nil, path: root, name: name, isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: name),
            FileNode(id: 2, parentID: 1, path: root + "/folder", name: "folder", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: name + "folder"),
            FileNode(id: 3, parentID: 2, path: root + "/folder/file", name: "file", isDirectory: false, logicalSize: 1024, allocatedSize: 4096, modified: nil, identity: name + "file")
        ])
        try await index.aggregate()
        return index
    }

    private func discard(_ index: ScanIndex) async {
        let url = index.url
        await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    @Test func replacingExplorerSessionClearsNavigationAndSelection() async throws {
        let first = try await index(name: "first")
        let second = try await index(name: "second")
        let model = ExplorerViewModel(settings: SettingsViewModel())
        await model.attach(first, options: ScanOptions())
        model.select(2)
        #expect(model.selected?.name == "folder")
        // A pending debounced query must not restore the previous session after reset.
        model.search = "file"
        model.scheduleRefresh()
        model.reset()
        await model.attach(second, options: ScanOptions())
        try await Task.sleep(for: .milliseconds(230))
        #expect(model.current?.name == "second")
        #expect(model.selected == nil)
        #expect(model.back.isEmpty && model.forward.isEmpty)
        #expect(model.rows.allSatisfy { $0.path.hasPrefix("/fixture/second/") })
        #expect(model.breadcrumbs.map(\.name) == ["second"])
        model.reset()
        await discard(first); await discard(second)
    }

    @Test func settingsPersistAcrossPresentationModels() throws {
        let suite = "DiskUnbloatTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsViewModel(defaults: defaults)
        model.largeGB = 4.5; model.ageDays = 90
        let restored = SettingsViewModel(defaults: defaults)
        #expect(restored.largeGB == 4.5)
        #expect(restored.ageDays == 90)
    }

    @Test func cleanupOwnsBasketAndDelegatesReviewedPlan() async throws {
        let index = try await index(name: "cleanup")
        let service = RecordingCleanupService()
        let model = CleanupViewModel(service: service)
        let root = URL(fileURLWithPath: "/fixture/cleanup")
        let folder = try #require(await index.node(2))
        let file = try #require(await index.node(3))
        #expect(model.add(file, root: root) == nil)
        #expect(model.add(folder, root: root) == nil)
        #expect(model.basket.map(\.id) == [2])
        let items = try #require(model.begin())
        #expect(model.cleaning)
        #expect(model.begin() == nil)
        let succeeded = await model.execute(items, root: root, index: index, mode: .trash)
        #expect(!succeeded)
        #expect(!model.cleaning)
        let plans = await service.plans
        #expect(plans.count == 1)
        #expect(plans.first?.items.map(\.id) == [2])
        #expect(plans.first?.ancestorIdentities[root.path] == "cleanup")
        await discard(index)
    }

    @Test func cleanupQueueAcceptsCuratedManagedCacheLocationsOnly() async throws {
        let service = RecordingCleanupService()
        let model = CleanupViewModel(service: service, homePath: "/Users/xdbtest")
        let root = URL(fileURLWithPath: "/Users/xdbtest")
        let parent = FileNode(id: 10, parentID: nil, path: "/Users/xdbtest/Library/Application Support/Code - Insiders", name: "Code - Insiders", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "10")
        let telegram = FileNode(id: 11, parentID: nil, path: "/Users/xdbtest/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", name: "6N38VWS5BX.ru.keepcoder.Telegram", isDirectory: true, logicalSize: 5, allocatedSize: 5, modified: Date().addingTimeInterval(-90 * 86400), identity: "11")
        // The managed parent stays protected; the curated cache location can join the queue.
        #expect(model.add(parent, root: root) != nil)
        #expect(model.add(telegram, root: root) == nil)
        #expect(model.basket.map(\.id) == [11])
        let items = try #require(model.begin())
        await model.execute(items, root: root, index: try await index(name: "unused"), mode: .trash)
        let plans = await service.plans
        #expect(plans.first?.knownCacheRoots.contains { $0.hasSuffix("/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram") } == true)
    }

    @Test func queuedItemsDisappearFromMapBrowserAndSelection() async throws {
        let model = ExplorerViewModel(settings: SettingsViewModel())
        let index = try await index(name: "queue")
        await model.attach(index, options: ScanOptions())
        #expect(model.rows.map(\.id) == [2])
        model.select(2)
        model.updateHiddenPaths(["/fixture/queue/folder"])
        try await Task.sleep(for: .milliseconds(230))
        #expect(model.hiddenPaths == ["/fixture/queue/folder"])
        #expect(model.rows.isEmpty)
        #expect(!model.scene.entries.contains { $0.id == 2 })
        #expect(model.selected == nil)
        model.updateHiddenPaths([])
        try await Task.sleep(for: .milliseconds(230))
        #expect(model.rows.map(\.id) == [2])
        #expect(model.scene.entries.contains { $0.id == 2 })
        await discard(index)
    }

    @Test func candidateExclusionsHideItemsAndRestore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let index = try ScanIndex(url: url)
        let old = Date().addingTimeInterval(-90 * 86400)
        func node(_ id: Int64, _ parent: Int64?, _ path: String, _ date: Date?) -> FileNode {
            FileNode(id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: true, logicalSize: 4096, allocatedSize: 4096, modified: date, identity: "\(id)")
        }
        try await index.insert([
            node(1, nil, "/Users/xdbtest/Library", old), node(2, 1, "/Users/xdbtest/Library/Caches", old),
            node(3, 2, "/Users/xdbtest/Library/Caches/AppOld", old), node(5, 2, "/Users/xdbtest/Library/Caches/AppRecent", Date())
        ])
        try await index.aggregate()
        let model = ExplorerViewModel(settings: SettingsViewModel(), userCacheRoot: URL(fileURLWithPath: "/Users/xdbtest/Library/Caches"))
        await model.attach(index, options: ScanOptions())
        model.drawerTab = .candidates
        model.candidateRule = .userCaches
        await model.loadRows()
        let oldCache = try #require(model.rows.first { $0.name == "AppOld" })
        #expect(!model.rows.contains { $0.name == "AppRecent" })
        model.excludeCandidate(oldCache)
        try await Task.sleep(for: .milliseconds(230))
        #expect(model.rows.isEmpty)
        model.restoreCandidateExclusion(oldCache.path)
        try await Task.sleep(for: .milliseconds(230))
        #expect(model.rows.map(\.name) == ["AppOld"])
        await discard(index)
    }

    @Test func windowSizeTargetsFollowPhases() {
        // Chooser and scan are compact; results and outcomes want the full window.
        #expect(WindowLayout.isCompact(.choosing) && WindowLayout.isCompact(.scanning) && WindowLayout.isCompact(.preparingResults))
        #expect(!WindowLayout.isCompact(.exploring) && !WindowLayout.isCompact(.cancelled) && !WindowLayout.isCompact(.failed("no access")))
        for size in [WindowLayout.compactSize, WindowLayout.compactMinimum] {
            #expect(size.width < WindowLayout.fullMinimum.width && size.height <= WindowLayout.fullMinimum.height)
        }
        // Restoring grows to the remembered size, the scan-time frame (user may have enlarged),
        // or the 960 × 640 minimum — whichever is largest.
        #expect(WindowLayout.restoredSize(remembered: .zero, current: WindowLayout.compactSize) == WindowLayout.fullMinimum)
        #expect(WindowLayout.restoredSize(remembered: CGSize(width: 1200, height: 800), current: WindowLayout.compactSize) == CGSize(width: 1200, height: 800))
        #expect(WindowLayout.restoredSize(remembered: CGSize(width: 1200, height: 800), current: CGSize(width: 1400, height: 900)) == CGSize(width: 1400, height: 900))
        #expect(WindowLayout.restoredSize(remembered: CGSize(width: 800, height: 500), current: WindowLayout.compactSize) == WindowLayout.fullMinimum)
    }
}
