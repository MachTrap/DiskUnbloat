import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct AnalysisFeatureTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloatRefresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("branch"), withIntermediateDirectories: true)
        try Data(repeating: 1,count: 100).write(to: root.appendingPathComponent("branch/a.mp4"))
        return root
    }

    @Test func performCleanupReturnsToStartScreenInsteadOfRescanning() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel(cleanupService: SucceedingCleanupService())
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let index = try #require(model.scan.index)
        let branch = try #require(await index.node(path: canonicalURL(root).path + "/branch"))
        // Queue the item directly: this fixture sits under the sandbox container tree, which
        // addToBasket's managed-data safety check refuses. This targets post-cleanup navigation.
        model.cleanup.basket = [branch]
        model.performCleanup(.trash)
        await model.waitForCleanup()
        #expect(model.phase == .choosing)
        #expect(model.cleanup.basket.isEmpty)
        await model.shutdown()
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
        // Category statistics materialize on the Types tab and cover every row in scope,
        // independent of the drawer's page-limited ranking.
        model.explorer.drawerTab = .types; await model.explorer.loadRows()
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
