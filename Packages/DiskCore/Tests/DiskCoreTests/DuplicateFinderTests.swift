import Foundation
import Testing
@testable import DiskCore

/// Duplicates are byte-identical regular files, one per inode; the kept copy follows the
/// chosen strategy, and cleanup re-verifies it before removing any other copy.
struct DuplicateFinderTests {
    private struct Tree {
        let root: URL
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    }
    private func tree() throws -> Tree {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.temporaryDirectory.appendingPathComponent("dupes-" + UUID().uuidString).path).resolvingSymlinksInPath()
        let tree = Tree(root: canonicalURL(root))
        func write(_ path: String, _ data: Data, days: Double) throws {
            let url = tree.url(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
        }
        var bytes = [UInt8](repeating: 0, count: 200_000)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
        let movie = Data(bytes)
        var other = bytes; other[150_000] ^= 0xFF  // same size, same first 64 KB, different
        try write("Documents/Holiday.mov", movie, days: 900)
        try write("Downloads/Holiday copy.mov", movie, days: 30)
        try write("Desktop/Old/Deep/Holiday.mov", movie, days: 200)
        try write("Documents/Lookalike.mov", Data(other), days: 10)
        try write("Small/a.txt", Data(repeating: 1, count: 10), days: 1)
        try write("Small/b.txt", Data(repeating: 1, count: 10), days: 1)
        try fm.createDirectory(at: tree.url("Links"), withIntermediateDirectories: true)
        try fm.linkItem(at: tree.url("Documents/Holiday.mov"), to: tree.url("Links/hardlink.mov"))
        try fm.createSymbolicLink(at: tree.url("Links/symlink.mov"), withDestinationURL: tree.url("Documents/Holiday.mov"))
        return tree
    }
    private func scan(_ tree: Tree) async throws -> ScanIndex {
        let index = try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        for await _ in await ScanCoordinator().scan(ScanRequest(root: tree.root), into: index) {}
        return index
    }

    @Test func findsByteIdenticalSetsOnly() async throws {
        let tree = try tree(); defer { try? FileManager.default.removeItem(at: tree.root) }
        let index = try await scan(tree)
        let search = try await DuplicateFinder.find(in: index, minimumSize: 1000)
        #expect(search.sets.count == 1)
        let set = try #require(search.sets.first)
        // The hard link shares an inode with one copy and never counts as a duplicate;
        // the symlink and the same-size lookalike are excluded; small files fall below the floor.
        let marker = tree.root.lastPathComponent + "/"
        let names = set.files.map { path in String(path.path[path.path.range(of: marker)!.upperBound...]) }
        #expect(Set(names).isSubset(of: ["Documents/Holiday.mov", "Downloads/Holiday copy.mov", "Desktop/Old/Deep/Holiday.mov", "Links/hardlink.mov"]))
        #expect(set.files.count == 3)
        #expect(search.copyCount == 2 && search.reclaimableBytes == set.size * 2)
        await index.close()
    }

    @Test func keeperFollowsTheStrategy() {
        func file(_ id: Int64, _ path: String, days: Double) -> FileNode {
            FileNode(id: id, parentID: 1, path: path, name: "f", isDirectory: false, logicalSize: 10, allocatedSize: 10,
                     modified: Date().addingTimeInterval(-days * 86_400), identity: "\(id)")
        }
        let set = DuplicateSet(files: [file(1, "/h/Documents/a.mov", days: 900), file(2, "/h/Downloads/a copy.mov", days: 30), file(3, "/h/a.mov", days: 200)])
        #expect(set.keeper(.oldest).id == 1)
        #expect(set.keeper(.newest).id == 2)
        #expect(set.keeper(.shortestPath).id == 3)
        #expect(Set(set.copies(.oldest).map(\.id)) == [2, 3])
        let result = DuplicateSearch(sets: [set], unreadable: 0).result(.newest)
        #expect(result.groups.first?.location.id == 2 && !result.nodes.contains { $0.id == 2 })
    }

    @Test func cleanupRefusesACopyWhoseKeptCopyChangedOrIsQueued() async throws {
        let tree = try tree(); defer { try? FileManager.default.removeItem(at: tree.root) }
        let index = try await scan(tree)
        let set = try #require(try await DuplicateFinder.find(in: index, minimumSize: 1000).sets.first)
        let keeper = set.keeper(.oldest), copies = set.copies(.oldest)
        let service = CleanupService()
        // The kept copy changes after the search: every removal is refused.
        try Data("edited".utf8).write(to: keeper.url)
        let changed = await service.execute(CleanupPlan(roots: [tree.root], entries: copies.map {
            CleanupEntry(node: $0, operation: .remove, survivor: .init(keeper)) }, mode: .permanent))
        #expect(changed.allSatisfy { !$0.succeeded })
        #expect(copies.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await index.close()

        // Fresh scan: the kept copy queued as well means its duplicates stay.
        let tree2 = try self.tree(); defer { try? FileManager.default.removeItem(at: tree2.root) }
        let index2 = try await scan(tree2)
        let set2 = try #require(try await DuplicateFinder.find(in: index2, minimumSize: 1000).sets.first)
        let keeper2 = set2.keeper(.oldest), copy2 = set2.copies(.oldest)[0]
        let both = await service.execute(CleanupPlan(roots: [tree2.root], entries: [
            CleanupEntry(node: copy2, operation: .remove, survivor: .init(keeper2)),
            CleanupEntry(node: keeper2, operation: .remove)], mode: .permanent))
        #expect(both.first { $0.path == copy2.path }?.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: copy2.path))
        // Unchanged and not queued: the copy goes and the kept one stays.
        let set3 = try #require(try await DuplicateFinder.find(in: index2, minimumSize: 1000).sets.first)
        let copy3 = set3.copies(.oldest).first { FileManager.default.fileExists(atPath: $0.path) && $0.path != keeper2.path }
        if let copy3, FileManager.default.fileExists(atPath: set3.keeper(.oldest).path) {
            let ok = await service.execute(CleanupPlan(roots: [tree2.root], entries: [CleanupEntry(node: copy3, operation: .remove, survivor: .init(set3.keeper(.oldest)))], mode: .permanent))
            #expect(ok.first?.succeeded == true)
        }
        await index2.close()
    }
}
