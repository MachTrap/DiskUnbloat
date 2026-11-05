import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Regression (reported by a tester): unchecking an item in the cleanup panel left it
/// missing from the map. With several queue changes in quick succession, a map load
/// started before the last change stored its scene, built for the old hidden paths, in
/// the scene cache, and the reload after the change was served that stale scene.
@MainActor struct UncheckRestoresMapTests {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("uncheck-" + UUID().uuidString).path)
        for (folder, size) in [("Downloads", 300_000), ("Desktop", 200_000), ("Documents", 150_000), ("Pictures", 100_000)] {
            let url = root.appendingPathComponent(folder + "/file.bin")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return root
    }

    /// Waits until every queued map reload has committed.
    private func settle(_ model: WorkspaceViewModel) async {
        for _ in 0..<400 {
            try? await Task.sleep(for: .milliseconds(10))
            if !model.explorer.isLoading { try? await Task.sleep(for: .milliseconds(30)); if !model.explorer.isLoading { return } }
        }
    }

    private func topNames(_ model: WorkspaceViewModel) -> Set<String> {
        Set(model.explorer.scene.entries.filter { $0.parentID == model.explorer.scene.rootID }.compactMap { $0.node?.name })
    }

    @Test func rapidCheckAndUncheckKeepsTheMapInSyncWithTheQueue() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel(fullDiskAccess: GrantedFullDiskAccess(), defaults: isolatedDefaults())
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let index = try #require(model.scan.index)
        let downloads = try #require(await index.node(path: canonicalURL(root).path + "/Downloads"))
        let desktop = try #require(await index.node(path: canonicalURL(root).path + "/Desktop"))
        for round in 0..<10 {
            // Check Downloads, check Desktop, uncheck Downloads — as fast as clicks arrive.
            // Real clicks leave the main actor free between them, so each change's map
            // reload is already running when the next click lands; an index round-trip
            // between toggles reproduces that.
            model.addToBasket(downloads)
            for _ in 0...(round % 3) { _ = await index.node(path: downloads.path) }
            model.addToBasket(desktop)
            for _ in 0...(round % 3) { _ = await index.node(path: desktop.path) }
            model.deselect(downloads)
            await settle(model)
            #expect(model.cleanup.basket.map(\.node.path) == [desktop.path])
            #expect(topNames(model).contains("Downloads"), "round \(round): unchecked Downloads is missing from the map")
            #expect(!topNames(model).contains("Desktop"), "round \(round): queued Desktop is still on the map")
            model.deselect(desktop)
            await settle(model)
            #expect(topNames(model).isSuperset(of: ["Downloads", "Desktop"]))
        }
        await model.shutdown()
    }
}
