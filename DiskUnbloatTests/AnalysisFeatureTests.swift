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
        model.cleanup.basket = [CleanupEntry(node: branch, operation: .remove)]
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
        model.cleanup.showQueue = false
        model.explorer.selectionIDs = [branch.id]
        model.addToBasket(branch)
        try Data(repeating: 1,count: 200).write(to: root.appendingPathComponent("branch/new.txt"))
        model.refreshFolder(branch)
        #expect(model.phase == .scanning)
        await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.scan.index === index)
        // The queue panel keeps its open/closed state across a focused refresh.
        #expect(!model.cleanup.showQueue)
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

    @Test func mapGeometryIsIndependentOfLegendHighlightAndDescriptionsComeFromCatalog() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel()
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let scene = model.explorer.scene
        model.explorer.highlightedCategory = .video
        // Category highlighting only dims the map; geometry never depends on it.
        #expect(model.explorer.scene == scene)
        // Descriptions exist only for curated locations, and never for other paths.
        let home = try #require(model.explorer.homePath)
        let caches = FileNode(id: 90,parentID: nil,path: home + "/Library/Caches",name: "Caches",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "90")
        #expect(model.explorer.description(for: caches) != nil)
        let unknown = FileNode(id: 91,parentID: nil,path: home + "/Projects",name: "Projects",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "91")
        #expect(model.explorer.description(for: unknown) == nil)
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
