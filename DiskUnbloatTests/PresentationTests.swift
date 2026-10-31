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

private actor RecordingCleanupService: CleanupServing {
    private(set) var plans: [CleanupPlan] = []
    func execute(_ plan: CleanupPlan) async -> [CleanupResult] {
        plans.append(plan)
        return [] // Records intent only; never touches real filesystem paths.
    }
}

@MainActor struct AuthorizationTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloatAuthorization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func bookmarkFailureDoesNotRejectPickerSelection() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "DiskUnbloatAuthorizationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = StubBookmarkAccess(url: url)
        bookmarks.creationError = CocoaError(.fileReadUnknown)
        let store = AuthorizationStore(defaults: defaults, bookmarks: bookmarks)
        let selected = try store.acceptSelection(url)
        #expect(selected == url)
        let request = ScanRequest(root: selected)
        store.retainOnly(request.roots)
        #expect(bookmarks.stopped.isEmpty)
        // Scopes unrelated to the scan can be released mid-session.
        store.retainOnly([URL(fileURLWithPath: "/elsewhere")])
        #expect(bookmarks.stopped.contains(selected))
        await store.waitForPendingBookmark()
        #expect(store.bookmarkWarning != nil)
        #expect(store.locations.isEmpty)
        store.release()
        #expect(bookmarks.started.count == 1 && bookmarks.stopped.count == 1)
    }

    @Test func savedSelectionRestoresAndRefreshFailureRemainsUsable() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "DiskUnbloatAuthorizationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = StubBookmarkAccess(url: url)
        let first = AuthorizationStore(defaults: defaults, bookmarks: bookmarks)
        _ = try first.acceptSelection(url)
        await first.waitForPendingBookmark()
        #expect(first.locations.count == 1)
        first.release()
        let restored = AuthorizationStore(defaults: defaults, bookmarks: bookmarks)
        let saved = try #require(restored.locations.first)
        bookmarks.isStale = true
        bookmarks.creationError = CocoaError(.fileReadUnknown)
        #expect(try await restored.restore(saved) == url)
        await restored.waitForPendingBookmark()
        #expect(restored.bookmarkWarning != nil)
        restored.release()
        #expect(bookmarks.started.count == bookmarks.stopped.count)
    }

    @Test func revokedSavedScopeIsNotAccepted() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmarks = StubBookmarkAccess(url: url)
        bookmarks.canStart = false
        let store = AuthorizationStore(bookmarks: bookmarks)
        let location = SavedLocation(id: UUID(), name: url.path, bookmark: Data([1]))
        await #expect(throws: (any Error).self) { try await store.restore(location) }
        #expect(bookmarks.stopped.isEmpty)
    }
}

@MainActor private final class StubBookmarkAccess: BookmarkAccessing {
    let url: URL
    var creationError: (any Error)?
    var canStart = true
    var isStale = false
    var started: [URL] = []
    var stopped: [URL] = []
    init(url: URL) { self.url = url }
    func makeBookmark(for url: URL) async throws -> Data {
        if let creationError { throw creationError }
        return Data([1])
    }
    func resolve(_ data: Data) async throws -> ResolvedBookmark { ResolvedBookmark(url: url, isStale: isStale) }
    func startAccessing(_ url: URL) -> Bool {
        guard canStart else { return false }
        started.append(url)
        return true
    }
    func stopAccessing(_ url: URL) { stopped.append(url) }
}

@MainActor struct MapFirstFlowTests {
    @Test func completedScanShowsMapWithSecondaryPanelsClosed() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        #expect(model.phase == .choosing)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan()
        #expect(model.phase == .scanning)
        #expect(!model.canClean)
        await scanner.ready()
        await scanner.finish()
        await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.explorer.scene.summary.knownBytes == 4096)
        #expect(!model.explorer.showFiles && !model.explorer.showDetails)
        #expect(model.canClean)
        await model.shutdown()
    }

    @Test func cancelledScanRequiresOptInForPartialMapAndDisablesCleanup() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready()
        model.cancel(); await model.waitForScan()
        #expect(model.phase == .cancelled)
        #expect(!model.canClean)
        model.viewPartialMap(); await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(!model.canClean)
        await model.shutdown()
    }

    @Test func completedPartialScanStillOpensKnownMap() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready(); await scanner.finish(partial: true); await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.scan.snapshot?.complete == false)
        #expect(model.explorer.scene.summary.knownBytes == 4096)
        await model.shutdown()
    }

    @Test func failureCanRetryWithoutShowingAnEmptyExplorer() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready()
        await scanner.finish(error: "Test failure"); await model.waitForScan()
        if case .failed = model.phase {} else { Issue.record("Failure must have a dedicated screen") }
        model.startScan(); await scanner.ready()
        await scanner.finish(); await model.waitForScan()
        #expect(model.phase == .exploring)
        await model.shutdown()
    }

    @Test func selectionTotalsDoNotDoubleCountParentAndChild() async throws {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready(); await scanner.finish(); await model.waitForScan()
        model.explorer.selectionIDs = [2,3]
        #expect(model.explorer.normalizedSelection.map(\.id) == [2])
        #expect(model.explorer.selectionBytes == 4096)
        let geometryBefore = model.explorer.scene
        model.explorer.highlightedCategory = .video
        #expect(model.explorer.scene == geometryBefore)
        await model.shutdown()
    }

    @Test func quickTargetsUseSuppliedRealHomeAndDropsRejectFiles() throws {
        let catalog = LocationCatalog(home: URL(fileURLWithPath: "/Users/tester"))
        #expect(catalog.targets.first?.url.path == "/Users/tester")
        #expect(catalog.targets.first { $0.id == "downloads" }?.url.path == "/Users/tester/Downloads")
        #expect(catalog.additional.map(\.url.path) == ["/Users/tester/Documents","/Users/tester/Pictures"])
        #expect(catalog.targets.first { $0.id == "xcode" }?.url.path == "/Users/tester/Library/Developer/Xcode/DerivedData")
        // Grouped quick actions stack several known locations under one synthetic map root.
        let caches = try #require(catalog.targets.first { $0.id == "allCaches" })
        let tools = try #require(catalog.targets.first { $0.id == "devTools" })
        #expect(caches.grouped && tools.grouped)
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Caches")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Code - Insiders/WebStorage")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/.npm/_cacache")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/Xcode/iOS DeviceSupport")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/CoreSimulator/Devices")))
        let homeTarget = try #require(catalog.targets.first { $0.id == "home" })
        #expect(!homeTarget.grouped && homeTarget.roots == [homeTarget.url])
        let model = LocationSelectionViewModel(catalog: catalog)
        #expect(throws: (any Error).self) { try model.directory(from: []) }
        #expect(throws: (any Error).self) { try model.directory(from: [URL(string: "https://example.com")!]) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try model.directory(from: [file]) }
    }
}

private actor ControlledScanner: ScanServing {
    private var continuation: AsyncStream<ScanEvent>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent> {
        try? await index.insert([
            FileNode(id: 1,parentID: nil,path: "/fixture",name: "fixture",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "1"),
            FileNode(id: 2,parentID: 1,path: "/fixture/folder",name: "folder",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "2"),
            FileNode(id: 3,parentID: 2,path: "/fixture/folder/movie.mov",name: "movie.mov",isDirectory: false,logicalSize: 100,allocatedSize: 4096,modified: nil,identity: "3")
        ])
        try? await index.aggregate()
        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.stage(.reading))
            continuation.yield(.progress(ScanSnapshot(items: 3,bytes: 4096,elapsed: 1,errors: 0,cancelled: false,complete: false,folders: 2,currentFolder: "/fixture/folder")))
            waiters.forEach { $0.resume() }; waiters = []
        }
    }
    func ready() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(error: String? = nil, partial: Bool = false) {
        if let error { continuation?.yield(.failed(error)) }
        else { continuation?.yield(.finished(ScanSnapshot(items: 3,bytes: 4096,elapsed: 1,errors: partial ? 1 : 0,cancelled: false,complete: !partial,folders: 2,currentFolder: "/fixture"))) }
        continuation?.finish(); continuation = nil
    }
    func cancel() {
        continuation?.yield(.finished(ScanSnapshot(items: 3,bytes: 4096,elapsed: 1,errors: 0,cancelled: true,complete: false,folders: 2,currentFolder: "/fixture")))
        continuation?.finish(); continuation = nil
    }
}

@MainActor struct BrowserPaginationTests {
    @Test func offPageSelectionsRemainAvailableForReview() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let index = try ScanIndex(url: url)
        let root = FileNode(id: 1,parentID: nil,path: "/paging",name: "paging",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "1")
        let files: [FileNode] = (2...601).map { id in
            FileNode(id: Int64(id),parentID: 1,path: "/paging/\(id)",name: "\(id)",isDirectory: false,logicalSize: 100,allocatedSize: 4096,modified: nil,identity: "\(id)")
        }
        try await index.insert([root] + files); try await index.aggregate()
        let model = ExplorerViewModel(settings: SettingsViewModel())
        await model.attach(index,options: ScanOptions())
        model.changePage(1); await model.waitForPage(); model.select(400)
        model.changePage(1); await model.waitForPage()
        #expect(model.selectionIDs == [400])
        #expect(model.selected?.name == "400")
        #expect(model.selectionBytes == 4096)
        #expect(model.totalRows == 600)
        model.reset(); await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}

@MainActor struct AnalysisFeatureTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloatRefresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("branch"), withIntermediateDirectories: true)
        try Data(repeating: 1,count: 100).write(to: root.appendingPathComponent("branch/a.mp4"))
        return root
    }

    @Test func folderRefreshRestoresPresentationAndInvalidatesOverlappingBasket() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel()
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let index = try #require(model.scan.index)
        let branch = try #require(await index.node(path: canonicalURL(root).path + "/branch"))
        model.explorer.showFiles = true; model.explorer.drawerTab = .largest; model.explorer.drawerHeight = 230
        model.explorer.showDetails = true; model.explorer.selectionIDs = [branch.id]
        model.addToBasket(branch)
        try Data(repeating: 1,count: 200).write(to: root.appendingPathComponent("branch/new.txt"))
        model.refreshFolder(branch)
        #expect(model.phase == .scanning)
        await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.scan.index === index)
        #expect(model.explorer.showFiles && model.explorer.showDetails)
        #expect(model.explorer.drawerTab == .largest && model.explorer.drawerHeight == 230)
        #expect(model.explorer.selectionIDs == [branch.id])
        #expect(model.cleanup.basket.isEmpty)
        #expect(await index.node(branch.id)?.logicalSize == 300)
        await model.shutdown()
    }

    @Test func cancelledFolderRefreshRetainsOriginalResults() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel()
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let index = try #require(model.scan.index)
        let branch = try #require(await index.node(path: canonicalURL(root).path + "/branch"))
        let revision = await index.revision
        model.refreshFolder(branch); model.cancel(); await model.waitForScan()
        #expect(model.phase == .cancelled)
        #expect(await index.revision == revision)
        model.returnToPreviousMap()
        #expect(model.phase == .exploring && model.canClean)
        await model.shutdown()
    }

    @Test func drawerRankingDoesNotChangeMapAndStatisticsUseAllRows() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel()
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let scene = model.explorer.scene
        model.explorer.drawerTab = .largest; await model.explorer.loadRows()
        #expect(model.explorer.scene == scene)
        #expect(model.explorer.rows.first?.name == "a.mp4")
        #expect(model.explorer.categories.first?.category == .video)
        #expect(model.explorer.categories.first?.count == 1)
        await model.shutdown()
    }

    @Test func busyDockRequestsDoNotReplaceCurrentScan() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture"); model.startScan(); await scanner.ready()
        #expect(!model.openLocations([URL(fileURLWithPath: "/another")]))
        #expect(model.scan.root?.path == "/fixture" && model.message != nil)
        await scanner.finish(); await model.waitForScan(); await model.shutdown()
    }

    @Test func knownRunningCacheOwnersCannotEnterReview() {
        let home = "/Users/activity"
        let cleanup = CleanupViewModel(service: RecordingCleanupService(),homePath: home,activity: FixedActivity(paths: [home+"/Library/Caches/running"]))
        let node = FileNode(id: 2,parentID: 1,path: home+"/Library/Caches/running/a",name: "a",isDirectory: false,logicalSize: 1,allocatedSize: 1,modified: nil,identity: "a")
        #expect(cleanup.add(node,root: URL(fileURLWithPath: home)) != nil)
        #expect(cleanup.basket.isEmpty)
    }
}

@MainActor private struct FixedActivity: ApplicationActivityProviding {
    let paths: [String]
    func blockedCachePaths(home: String) -> [String] { paths }
}

@MainActor struct NativeOpenTests {
    @Test func coldLaunchOpenIsBufferedUntilWorkspaceIsAttached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloatDock-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = AppDelegate()
        #expect(delegate.routeOpen([root]))
        let model = WorkspaceViewModel()
        #expect(model.phase == .choosing)
        delegate.model = model
        #expect(model.phase == .scanning)
        await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.scan.root == root)
        await model.shutdown()
    }

    @Test func multipleNativeOpenLocationsAreRejected() async {
        let model = WorkspaceViewModel()
        let delegate = AppDelegate(); delegate.model = model
        #expect(!delegate.routeOpen([URL(fileURLWithPath: "/a"),URL(fileURLWithPath: "/b")]))
        #expect(model.phase == .choosing && model.message != nil)
        await model.shutdown()
    }
}

@MainActor struct LocalizationTests {
    @Test func catalogsContainRussianPluralFormsAndStablePaths() throws {
        let path = try #require(Bundle.main.path(forResource: "Localizable",ofType: "stringsdict",inDirectory: "ru.lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: data,format: nil) as? [String: Any])
        #expect(dictionary["%lld items"] != nil)
        let home = URL(fileURLWithPath: "/Users/localization")
        let catalog = LocationCatalog(home: home)
        #expect(catalog.targets.first { $0.id == "downloads" }?.url.lastPathComponent == "Downloads")
        #expect(catalog.additional.map(\.id) == ["Documents","Pictures"])
    }
}

@MainActor struct PartialRefreshSafetyTests {
    @Test func branchRefreshCannotUpgradeCancelledWholeScanToComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloatPartial-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("branch"),withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("branch/a"))
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel(coordinator: InitiallyPartialScanner())
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        #expect(model.phase == .cancelled)
        model.viewPartialMap(); await model.waitForScan()
        let index = try #require(model.scan.index)
        let branch = try #require(await index.node(path: canonicalURL(root).path+"/branch"))
        model.refreshFolder(branch); await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(!model.canClean && model.scan.snapshot?.cancelled == true)
        let scanRoot = try #require(await index.node(1))
        model.refreshFolder(scanRoot); await model.waitForScan()
        #expect(model.canClean && model.scan.snapshot?.complete == true)
        await model.shutdown()
    }

    @Test func volumeRootAllowsDescendantRefreshRequests() {
        let model = ScanViewModel(coordinator: ScanCoordinator())
        model.root = URL(fileURLWithPath: "/")
        let folder = FileNode(id: 2,parentID: 1,path: "/Users",name: "Users",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "fixture")
        #expect(model.prepareRefresh(folder)?.root.path == "/Users")
    }
}

private actor InitiallyPartialScanner: ScanServing {
    private var first = true
    private let scanner = ScanCoordinator()
    func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent> {
        let stream = await scanner.scan(request,into: index)
        guard first else { return stream }
        first = false
        return AsyncStream { continuation in
            Task {
                for await event in stream {
                    if case .finished(let result) = event {
                        continuation.yield(.finished(ScanSnapshot(items: result.items,bytes: result.bytes,elapsed: result.elapsed,errors: result.errors,cancelled: true,complete: false,folders: result.folders,currentFolder: result.currentFolder)))
                    } else { continuation.yield(event) }
                }
                continuation.finish()
            }
        }
    }
    func cancel() async { await scanner.cancel() }
}

struct MapInputTests {
    @Test func horizontalHistoryIsOncePerGestureAndIgnoresVerticalMomentum() {
        var input = MapHistoryGesture()
        #expect(input.scroll(x: 10,y: 100,began: true,precise: true,momentum: false,timestamp: 1) == nil)
        #expect(input.scroll(x: 100,y: 2,began: true,precise: true,momentum: true,timestamp: 2) == nil)
        #expect(input.scroll(x: 75,y: 2,began: true,precise: true,momentum: false,timestamp: 3) == true)
        #expect(input.scroll(x: 75,y: 2,began: false,precise: true,momentum: false,timestamp: 4) == nil)
        #expect(input.swipe(x: 1,y: 0,timestamp: 3.1) == nil)
        #expect(input.scroll(x: -75,y: 2,began: true,precise: true,momentum: false,timestamp: 5) == false)
        #expect(input.swipe(x: 1,y: 0,timestamp: 6) == true)
    }
}

@MainActor struct GroupedScanTests {
    /// One synthetic wrapper node above two real roots; identical shape to grouped scans.
    private func groupedIndex() async throws -> ScanIndex {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let index = try ScanIndex(url: url)
        try await index.insert([
            FileNode(id: 1, parentID: nil, path: ScanGroup.path, name: "All caches", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: ScanGroup.path),
            FileNode(id: 2, parentID: 1, path: "/Users/gro/Library/Caches", name: "Caches", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "2"),
            FileNode(id: 3, parentID: 2, path: "/Users/gro/Library/Caches/song.mp3", name: "song.mp3", isDirectory: false, logicalSize: 10, allocatedSize: 10, modified: nil, identity: "3"),
            FileNode(id: 4, parentID: 1, path: "/Users/gro/.npm/_cacache", name: "_cacache", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "4"),
            FileNode(id: 5, parentID: 4, path: "/Users/gro/.npm/_cacache/clip.mp3", name: "clip.mp3", isDirectory: false, logicalSize: 20, allocatedSize: 20, modified: nil, identity: "5")
        ])
        try await index.aggregate()
        return index
    }

    private func discard(_ index: ScanIndex) async {
        let url = index.url
        await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    @Test func groupedExplorerSearchAtWrapperSpansEveryListedRoot() async throws {
        let index = try await groupedIndex()
        defer { Task { await discard(index) } }
        let model = ExplorerViewModel(settings: SettingsViewModel())
        await model.attach(index, options: ScanOptions(), grouped: true)
        #expect(model.current?.isGroupRoot == true)
        #expect(model.breadcrumbs.map(\.name) == ["All caches"])
        // Filtering while focused on the wrapper searches the union of all listed locations.
        model.search = "mp3"
        model.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(240))
        #expect(Set(model.rows.map(\.id)) == [3, 5])
        // Inside one root the same filter is scoped to that subtree only.
        let caches = try #require(await index.node(2))
        model.navigate(caches)
        await model.waitForPage()
        model.search = "mp3"
        model.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(240))
        #expect(model.rows.map(\.id) == [3])
        #expect(model.breadcrumbs.map(\.name) == ["All caches", "Caches"])
        model.reset(); await discard(index)
    }

    @Test func groupedRequestsPrepareScopesAndRefreshInsideAnyRoot() async throws {
        let scanner = ControlledScanner()
        let model = ScanViewModel(coordinator: scanner)
        let first = URL(fileURLWithPath: "/Users/grouped/Library/Caches")
        let second = URL(fileURLWithPath: "/Users/grouped/.npm/_cacache")
        model.pendingGroup = PendingGroup(title: "All caches", roots: [first, second])
        let request = try #require(model.prepare())
        #expect(model.isGroupScan)
        #expect(model.roots.map(\.path) == [first.path, second.path])
        #expect(model.groupTitle == "All caches")
        #expect(request.root == first)
        #expect(request.extraRoots.map(\.path) == [second.path])
        #expect(request.groupTitle == "All caches")
        let task = Task { try await model.run(request) }
        await scanner.ready()
        await scanner.finish()
        try await task.value
        #expect(model.scanning == false)
        // A secondary root's folder can refresh against its own scope.
        let child = FileNode(id: 9, parentID: 2, path: second.path + "/sub", name: "sub", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "9")
        let refresh = try #require(model.prepareRefresh(child))
        #expect(refresh.root.path == second.path + "/sub")
        // The test paths do not exist, so the refresh probe fails and unwinds the flag.
        try? await model.runRefresh(refresh, node: child)
        #expect(model.scanning == false)
        // Locations outside every listed scope and the synthetic wrapper are refused here.
        let elsewhere = FileNode(id: 10, parentID: 2, path: "/Users/grouped/Downloads", name: "Downloads", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "10")
        #expect(model.prepareRefresh(elsewhere) == nil)
        let wrapper = FileNode(id: 1, parentID: nil, path: ScanGroup.path, name: "All caches", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: ScanGroup.path)
        #expect(wrapper.isGroupRoot)
        #expect(model.prepareRefresh(wrapper) == nil)
        // The rescan after a cleanup reuses the whole grouped scope, not just the first root.
        let rescan = try #require(model.prepare())
        #expect(rescan.extraRoots.map(\.path) == [second.path])
        #expect(rescan.groupTitle == "All caches")
        await model.discardIndex()
    }

    @Test func singleRootSelectionClearsGroupedScope() async throws {
        let scanner = ControlledScanner()
        let model = ScanViewModel(coordinator: scanner)
        model.pendingGroup = PendingGroup(title: "All caches", roots: [URL(fileURLWithPath: "/Users/gro/Library/Caches"), URL(fileURLWithPath: "/Users/gro/.npm/_cacache")])
        let grouped = try #require(model.prepare())
        let task = Task { try await model.run(grouped) }
        await scanner.ready()
        await scanner.finish()
        try await task.value
        // A new single-folder selection replaces the grouped scope entirely.
        model.pendingRoot = URL(fileURLWithPath: "/Users/gro/Downloads")
        let single = try #require(model.prepare())
        #expect(!model.isGroupScan)
        #expect(single.extraRoots.isEmpty && single.groupTitle.isEmpty)
        await model.discardIndex()
    }
}
