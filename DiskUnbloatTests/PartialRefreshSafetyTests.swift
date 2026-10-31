import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

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
