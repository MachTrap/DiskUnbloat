import Foundation
import Testing
@testable import DiskCore

/// Map hiding at bulk-selection scale. A rebuildable quick-select queues well over a
/// thousand entries; the map query once expressed them as one flat conjunction and
/// SQLite rejected the statement above its expression-depth limit ("Expression tree is
/// too large") — silently, leaving the map completely empty while the header still
/// showed the root's visible size. These tests pin the balanced-clause behavior and the
/// honest accounting of fully collapsed containers.
@Suite struct MapHidingBulkTests {
    private func discard(_ index: ScanIndex) async {
        let url = index.url
        await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// A tree of project directories: each project holds `fanout` module folders of
    /// `fanout` leaf files, and the leaf files of the first `hiddenTrees` project trees
    /// form the queued paths — the deep, non-collapsible shape of a real bulk selection.
    private func bulkIndex(rootPath: String, trees: Int, fanout: Int, hiddenTrees: Int) async throws -> (ScanIndex, [String]) {
        let index = try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        var nodes: [FileNode] = [
            FileNode(id: 1, parentID: nil, path: rootPath, name: "root", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "1")
        ]
        var id: Int64 = 2
        var hidden: [String] = []
        for tree in 0..<trees {
            let top = FileNode(id: id, parentID: 1, path: rootPath + "/project-\(tree)", name: "project-\(tree)", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "\(id)")
            id += 1; nodes.append(top)
            for module in 0..<fanout {
                let mid = FileNode(id: id, parentID: top.id, path: top.path + "/module-\(module)", name: "module-\(module)", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "\(id)")
                id += 1; nodes.append(mid)
                for leaf in 0..<fanout {
                    let kept = tree >= hiddenTrees
                let path = mid.path + "/artifact-\(leaf).\(kept ? "o" : "bin")"
                    nodes.append(FileNode(id: id, parentID: mid.id, path: path, name: "artifact-\(leaf).\(kept ? "o" : "bin")", isDirectory: false, logicalSize: 8192, allocatedSize: 8192, modified: nil, identity: "\(id)"))
                    if tree < hiddenTrees { hidden.append(path) }
                    id += 1
                }
            }
        }
        try await index.insert(nodes)
        try await index.aggregate()
        return (index, hidden)
    }

    @Test func rootQuerySurvivesMoreThanOneThousandHiddenPaths() async throws {
        // 36 trees x 8x8 files: 1536 hidden paths — well past the depth that once
        // rejected the whole statement and blanked the map.
        let (index, hidden) = try await bulkIndex(rootPath: "/bulk", trees: 36, fanout: 8, hiddenTrees: 24)
        defer { Task { await discard(index) } }
        #expect(hidden.count >= 1500)
        let kept = HiddenRanges.pruneSubsumed(hidden)
        var q = FileQuery(); q.parentID = 1
        q.hiddenPaths = kept
        #expect(await index.query(q).count == 36) // every project row still resolves
        let scene = await index.mapScene(rootID: 1, query: q, filtered: false)
        let top = scene.entries.filter { $0.ownerID == 1 }
        #expect(top.count == 36)
        // The 24 fully queued trees vanish to zero visible bytes; the 12 surviving trees
        // keep their exact content size, and the header total matches.
        #expect(top.filter { $0.bytes == 8 * 8 * 8192 }.count == 12)
        #expect(top.filter { $0.bytes <= 0 }.count == 24)
        #expect(scene.summary.knownBytes == 12 * 8 * 8 * 8192)
    }

    @Test func collapsedSubtreeBytesLeaveAncestorsHonest() async throws {
        // One project with every leaf file queued collapses its modules into
        // descendants-only ranges; the project's own tile and the root total lose exactly
        // the queued files' bytes, matching the queue's estimate.
        let (index, hidden) = try await bulkIndex(rootPath: "/collapse", trees: 2, fanout: 4, hiddenTrees: 1)
        defer { Task { await discard(index) } }
        let ranges = await index.coalescedHiddenRanges(for: hidden)
        #expect(ranges.subtrees == Array((0..<4).map { "/collapse/project-0/module-\($0)" }))
        #expect(ranges.paths.isEmpty)
        var q = FileQuery(); q.parentID = 1
        q.hiddenPaths = ranges.paths; q.hiddenSubtrees = ranges.subtrees
        let scene = await index.mapScene(rootID: 1, query: q, filtered: false)
        #expect(try #require(scene.entries.first { $0.node?.name == "project-1" }).bytes == 4 * 4 * 8192)
        #expect(scene.summary.knownBytes == 4 * 4 * 8192)
        // The emptied project survives with no visible bytes.
        #expect(scene.entries.first { $0.node?.name == "project-0" }!.bytes <= 0)
        // And the collapsed modules stay in scope as rows: only their content hides.
        var all = FileQuery()
        all.hiddenPaths = ranges.paths; all.hiddenSubtrees = ranges.subtrees
        #expect(await index.query(all).contains { $0.path == "/collapse/project-0/module-0" })
        // The legend tracks what the query still holds: the hidden leaves (.bin → Other)
        // leave the category list while the kept rows' categories remain (.o → Dev).
        let categories = Set(await index.categoryList(all))
        #expect(categories == [.development])
    }
}
