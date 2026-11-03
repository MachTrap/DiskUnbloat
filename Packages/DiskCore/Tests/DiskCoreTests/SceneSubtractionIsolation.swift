import Foundation
import Testing
@testable import DiskCore

/// Core-level isolation of the explorer failure observed on real field data: the map
/// scene must subtract the queued folders' bytes from every containing tile when the
/// hidden paths are present in the query.
@Suite struct SceneSubtractionIsolation {
    private func discard(_ index: ScanIndex) async {
        let url = index.url
        await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    @Test func mapSceneSubtractsQueuedFoldersAtScale() async throws {
        let index = try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        defer { Task { await discard(index) } }
        let root = "/iso"
        var id: Int64 = 2
        var nodes: [FileNode] = [
            FileNode(id: 1, parentID: nil, path: root, name: "root", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "1"),
            FileNode(id: id, parentID: 1, path: root + "/CODE", name: "CODE", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "\(id)"),
        ]
        let codeID = id; id += 1
        var hidden: [String] = []
        for tree in 0..<1100 {
            let treePath = root + "/CODE/tree\(tree)"
            nodes.append(FileNode(id: id, parentID: codeID, path: treePath, name: "tree\(tree)", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "\(id)")); let treeID = id; id += 1
            nodes.append(FileNode(id: id, parentID: treeID, path: treePath + "/node_modules", name: "node_modules", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "\(id)")); let nmID = id; id += 1
            nodes.append(FileNode(id: id, parentID: nmID, path: treePath + "/node_modules/file.bin", name: "file.bin", isDirectory: false, logicalSize: 4096, allocatedSize: 4096, modified: nil, identity: "\(id)")); id += 1
            nodes.append(FileNode(id: id, parentID: treeID, path: treePath + "/src", name: "src", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "\(id)")); let srcID = id; id += 1
            nodes.append(FileNode(id: id, parentID: srcID, path: treePath + "/src/main.swift", name: "main.swift", isDirectory: false, logicalSize: 2048, allocatedSize: 2048, modified: nil, identity: "\(id)")); id += 1
            hidden.append(treePath + "/node_modules")
        }
        try await index.insert(nodes)
        try await index.aggregate()
        let ranges = await index.coalescedHiddenRanges(for: hidden)
        #expect(ranges.paths.count == 1100)
        #expect(ranges.subtrees.isEmpty)
        var q = FileQuery(); q.parentID = 1
        q.hiddenPaths = ranges.paths; q.hiddenSubtrees = ranges.subtrees
        let scene = await index.mapScene(rootID: 1, query: q, filtered: false)
        let code = scene.entries.first { $0.node?.name == "CODE" }
        #expect(try #require(code).bytes == 1100 * 2048)
        #expect(scene.summary.knownBytes == 1100 * 2048)
    }
}
