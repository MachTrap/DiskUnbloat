import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

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
        #expect(Set(model.scene.entries.map(\.id)) == [3, 5])
        // Inside one root the same filter is scoped to that subtree only.
        let caches = try #require(await index.node(2))
        model.navigate(caches)
        model.search = "mp3"
        model.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(240))
        #expect(model.scene.entries.map(\.id) == [3])
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
