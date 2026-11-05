import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// The unreached tile appears only on the unfiltered root view of a volume scan, can be
/// hidden, and never becomes a selectable or cleanable item.
@MainActor struct UnreachedSpaceTests {
    @Test func tileAppearsAtTheRootOnlyAndHidesOnRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unreached-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data(count: 40_000).write(to: root.appendingPathComponent("Folder/file.bin"))
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel(fullDiskAccess: GrantedFullDiskAccess(), defaults: isolatedDefaults())
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let explorer = model.explorer
        // A temporary folder is not a volume root: nothing is invented for it.
        #expect(explorer.unreached == nil)
        #expect(!explorer.scene.entries.contains { $0.kind == .unreached })
        explorer.setUnreached(UnreachedSpace(bytes: 1 << 30, purgeable: nil, localSnapshots: 2, unreadableLocations: 0))
        await explorer.loadResults()
        let tile = try #require(explorer.scene.entries.first { $0.kind == .unreached })
        #expect(tile.node == nil && tile.bytes == 1 << 30)
        // Selecting it does nothing; it has no node to queue.
        explorer.select(tile, extending: false)
        #expect(explorer.selectionIDs.isEmpty)
        // The known total is the scan's, never inflated by the estimate.
        #expect(explorer.scene.summary.knownBytes < 1 << 30)
        explorer.showUnreached = false
        await explorer.loadResults()
        #expect(!explorer.scene.entries.contains { $0.kind == .unreached })
        explorer.showUnreached = true
        // Below the root it never appears.
        let folder = try #require(explorer.scene.entries.first { $0.node?.name == "Folder" }?.node)
        explorer.navigate(folder)
        await explorer.loadResults()
        #expect(!explorer.scene.entries.contains { $0.kind == .unreached })
        await model.shutdown()
    }

    @Test func volumeRootDetection() {
        #expect(VolumeSpaceService.isVolumeRoot(URL(fileURLWithPath: "/")))
        #expect(!VolumeSpaceService.isVolumeRoot(FileManager.default.temporaryDirectory))
        #expect((VolumeSpaceService.usedBytes(URL(fileURLWithPath: "/")) ?? 0) > 0)
    }
}
