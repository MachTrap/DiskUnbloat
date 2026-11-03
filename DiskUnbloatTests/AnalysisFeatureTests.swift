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

    @Test func successfulCleanupRescansTheScopeAndReturnsToTheUpdatedMap() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel(cleanupService: SucceedingCleanupService())
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let oldIndex = try #require(model.scan.index)
        let branch = try #require(await oldIndex.node(path: canonicalURL(root).path + "/branch"))
        // Queue the item directly: this fixture sits under the sandbox container tree, which
        // addToBasket's managed-data safety check refuses. This targets post-cleanup navigation.
        model.cleanup.basket = [CleanupEntry(node: branch, operation: .remove)]
        // The real cleanup service deletes the entries; simulate that here so the rescan
        // can assert the map no longer carries the removed branch.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("branch"))
        model.performCleanup(.trash)
        await model.waitForCleanup()
        await model.waitForScan()
        // The app reruns the scan of the same scope on the spot and lands on the updated
        // map: the deleted branch is gone, a fresh index carries the result, and the
        // deletion report stays available. The chooser is never shown.
        #expect(model.phase == .exploring)
        #expect(model.cleanup.basket.isEmpty)
        #expect(model.cleanup.showReport)
        let newIndex = try #require(model.scan.index)
        #expect(newIndex !== oldIndex)
        #expect(await newIndex.node(path: canonicalURL(root).path + "/branch") == nil)
        #expect(model.canClean)
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
        // The queued branch's map selection left with it (queued items cannot stay
        // selected); the refresh removed it from the queue, so the selection rests
        // cleared rather than pointing at a stale highlight.
        #expect(model.explorer.selectionIDs.isEmpty)
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

    @Test func refusedWholeFolderSelectionClearsTheNestedSelection() {
        let home = "/Users/partial"
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: home, activity: FixedActivity(paths: [home + "/Library/Caches/running-app"]))
        let root = URL(fileURLWithPath: home)
        // A queued cache beneath ~/Library/Caches that is itself selectable only because
        // it is not the running app's path the activity check blocks.
        let inner = FileNode(id: 3,parentID: 2,path: home+"/Library/Caches/harmless-cache",name: "harmless-cache",isDirectory: true,logicalSize: 10,allocatedSize: 10,modified: nil,identity: "3")
        let caches = FileNode(id: 2,parentID: 1,path: home+"/Library/Caches",name: "Caches",isDirectory: true,logicalSize: 100,allocatedSize: 100,modified: nil,identity: "2")
        #expect(cleanup.add(inner, root: root) == nil)
        #expect(cleanup.basket.count == 1)
        // The whole-folder select is refused (the Caches path overlaps the running app's
        // blocked cache), so the click must clear the nested selection instead of only
        // alerting, and the shown message keeps the refusal plus what happened.
        let message = cleanup.addOrClear(caches, roots: [root])
        #expect(message == L10n.text("This selection includes cache data belonging to a running application or protected service. Close the application and review again.")
            + " " + L10n.text("The items already selected inside it were removed from the cleanup queue instead."))
        #expect(cleanup.basket.isEmpty)
    }

    @Test func refusedWholeFolderSelectionWithoutNestedEntriesStaysAPlainAlert() {
        let home = "/Users/partial-plain"
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: home, activity: FixedActivity(paths: [home + "/Library/Caches/running-app"]))
        let caches = FileNode(id: 2,parentID: 1,path: home+"/Library/Caches",name: "Caches",isDirectory: true,logicalSize: 100,allocatedSize: 100,modified: nil,identity: "2")
        // Nothing queued inside: the refusal surfaces alone and nothing changes.
        let message = cleanup.addOrClear(caches, roots: [URL(fileURLWithPath: home)])
        #expect(message == L10n.text("This selection includes cache data belonging to a running application or protected service. Close the application and review again."))
        #expect(cleanup.basket.isEmpty)
    }
}
