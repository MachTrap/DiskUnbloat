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
        #expect(model.scene.entries.compactMap(\.node).allSatisfy { $0.path.hasPrefix("/fixture/second/") })
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
        #expect(model.basket.map { $0.node.id } == [2])
        #expect(model.basket.map(\.operation) == [.remove])
        let items = try #require(model.begin())
        #expect(model.cleaning)
        #expect(model.begin() == nil)
        let succeeded = await model.execute(items, root: root, index: index, mode: .trash)
        #expect(!succeeded)
        #expect(!model.cleaning)
        let plans = await service.plans
        #expect(plans.count == 1)
        #expect(plans.first?.items.map { $0.node.id } == [2])
        #expect(plans.first?.ancestorIdentities[root.path] == "cleanup")
        await discard(index)
    }

    @Test func cleanupQueueAcceptsCuratedManagedCacheLocationsOnly() async throws {
        let service = RecordingCleanupService()
        // The wildcard root needs the real Telegram media tree on disk.
        let homePath = "/Users/Shared/DiskUnbloat-tgcache-" + UUID().uuidString
        let media = homePath + "/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/account-3/postbox/media"
        try FileManager.default.createDirectory(atPath: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: homePath) }
        let model = CleanupViewModel(service: service, homePath: homePath, activity: FixedActivity(paths: []))
        let root = URL(fileURLWithPath: homePath)
        let parent = FileNode(id: 10, parentID: nil, path: homePath + "/Library/Application Support/Code - Insiders", name: "Code - Insiders", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "10")
        let account = FileNode(id: 11, parentID: nil, path: homePath + "/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/account-3", name: "account-3", isDirectory: true, logicalSize: 5, allocatedSize: 5, modified: Date().addingTimeInterval(-90 * 86400), identity: "11")
        let mediaNode = FileNode(id: 12, parentID: 11, path: media, name: "media", isDirectory: true, logicalSize: 5, allocatedSize: 5, modified: Date().addingTimeInterval(-90 * 86400), identity: "12")
        // The managed parent stays protected; the curated media cache joins the queue,
        // and the account parent beside it is refused like any other managed data.
        #expect(model.add(parent, root: root) != nil)
        #expect(model.add(mediaNode, root: root) == nil)
        #expect(model.add(account, root: root) != nil)
        #expect(model.basket.map { $0.node.id } == [12])
        let items = try #require(model.begin())
        await model.execute(items, root: root, index: try await index(name: "unused"), mode: .trash)
        let plans = await service.plans
        #expect(plans.first?.knownCacheRoots.contains { $0.hasSuffix("/postbox/media") } == true)
    }

    @Test func scanRootsQueueAsCleanContentsKeepingTheFolder() async throws {
        let service = RecordingCleanupService()
        let model = CleanupViewModel(service: service, homePath: "/Users/xdbtest")
        let caches = URL(fileURLWithPath: "/Users/xdbtest/Library/Caches")
        func node(_ id: Int64, _ path: String) -> FileNode {
            FileNode(id: id, parentID: id == 1 ? nil : 1, path: path, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "\(id)")
        }
        // A scan-root folder cannot be removed, so queueing it cleans its contents in place.
        #expect(model.add(node(1, "/Users/xdbtest/Library/Caches"), roots: [caches]) == nil)
        #expect(model.basket.map(\.operation) == [.emptyContents])
        // Contents keep the ordinary removal path and collapse into the queued root.
        #expect(model.add(node(2, "/Users/xdbtest/Library/Caches/app"), roots: [caches]) == nil)
        #expect(model.basket.map { $0.node.id } == [1])
        // A managed scan root stays protected: emptying ~/Library is still refused.
        #expect(model.add(node(3, "/Users/xdbtest/Library"), roots: [URL(fileURLWithPath: "/Users/xdbtest/Library")]) != nil)
        #expect(model.basket.map { $0.node.id } == [1])
        let items = try #require(model.begin())
        await model.execute(items, roots: [caches], index: try await index(name: "unused"), mode: .trash)
        let plans = await service.plans
        #expect(plans.first?.items.map(\.operation) == [.emptyContents])
    }

    @Test func activeCachesGuardContentsWhileRootCleaningStaysQueued() {
        let home = "/Users/xactivity"
        let caches = URL(fileURLWithPath: home + "/Library/Caches")
        func dir(_ id: Int64, _ path: String) -> FileNode {
            FileNode(id: id, parentID: 1, path: path, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "\(id)")
        }
        // A running application's cache among the root's contents no longer blocks queueing the
        // root: every contents removal is rechecked against the activity guard at execution.
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: home, activity: FixedActivity(paths: [home + "/Library/Caches/running"]))
        #expect(cleanup.add(dir(1, caches.path), roots: [caches]) == nil)
        #expect(cleanup.basket.map(\.operation) == [.emptyContents])
        // The active cache itself still cannot be queued for removal.
        #expect(cleanup.add(dir(2, caches.path + "/running"), roots: [caches]) != nil)
        #expect(cleanup.basket.map { $0.node.id } == [1])
        // A scan root that is itself an active cache stays refused.
        let active = CleanupViewModel(service: RecordingCleanupService(), homePath: home, activity: FixedActivity(paths: [caches.path]))
        #expect(active.add(dir(3, caches.path), roots: [caches]) != nil)
        #expect(active.basket.isEmpty)
    }

    @Test func queuedItemsDisappearFromMapAndSelection() async throws {
        let model = ExplorerViewModel(settings: SettingsViewModel())
        let index = try await index(name: "queue")
        await model.attach(index, options: ScanOptions())
        #expect(model.scene.entries.contains { $0.id == 2 })
        model.select(2)
        await model.updateHiddenPaths(["/fixture/queue/folder"])
        try await Task.sleep(for: .milliseconds(230))
        #expect(model.hiddenPaths == ["/fixture/queue/folder"])
        #expect(!model.scene.entries.contains { $0.id == 2 })
        #expect(model.selected == nil)
        await model.updateHiddenPaths([])
        try await Task.sleep(for: .milliseconds(230))
        #expect(model.scene.entries.contains { $0.id == 2 })
        await discard(index)
    }

    @Test func selectionSurvivesSceneReloads() async throws {
        let model = ExplorerViewModel(settings: SettingsViewModel())
        let index = try await index(name: "selection")
        await model.attach(index, options: ScanOptions())
        model.select(2)
        model.metric = .logical
        await model.loadResults()
        #expect(model.selected?.name == "folder")
        #expect(model.selectionBytes == 1024)
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
