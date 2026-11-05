import Darwin
import Foundation
import Testing
@testable import DiskCore

/// Duplicates are byte-identical regular files, one per inode; the kept copy follows the
/// chosen strategy, and cleanup re-verifies it before removing any other copy.
struct DuplicateFinderTests {
    private struct Tree {
        let root: URL
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func write(_ path: String, bytes: Data) throws {
            let destination = url(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination)
        }
    }
    private func emptyTree() throws -> Tree {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return Tree(root: canonicalURL(root))
    }
    private func tree() throws -> Tree {
        let fm = FileManager.default
        let tree = try emptyTree()
        func write(_ path: String, _ data: Data, days: Double) throws {
            let url = tree.url(path)
            try tree.write(path, bytes: data)
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
    private func scan(_ tree: Tree, options: ScanOptions = .init()) async throws -> ScanIndex {
        let index = try ScanIndex(url: URL(fileURLWithPath: tree.root.path + ".sqlite"))
        for await _ in await ScanCoordinator().scan(ScanRequest(root: tree.root, options: options), into: index) {}
        return index
    }

    private func close(_ index: ScanIndex) async {
        await index.close()
        try? FileManager.default.removeItem(at: index.url)
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
        await close(index)
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
        let unknown = FileNode(id: 4, parentID: 1, path: "/h/0.mov", name: "0.mov", isDirectory: false,
                               logicalSize: 10, allocatedSize: 10, modified: nil, identity: "4")
        let withUnknown = DuplicateSet(files: set.files + [unknown])
        #expect(withUnknown.keeper(.newest).id == 2)
        #expect(withUnknown.keeper(.oldest).id == 1)
        #expect(withUnknown.keeper(.shortestPath).id == 4)
    }

    @Test func foldingKeepsExternalMatchesAndPairsSmallAndEmptyFiles() async throws {
        let tree = try emptyTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let large = Data(repeating: 83, count: 130_000)
        let inner = Data(repeating: 42, count: 110_000)
        for folder in ["left/Projects", "right/Old projects", "archive/Projects backup"] {
            try tree.write(folder + "/Large.bin", bytes: large)
            try tree.write(folder + "/Nested/Other.bin", bytes: inner)
            try tree.write(folder + "/Nested/Small.txt", bytes: Data("same".utf8))
            try tree.write(folder + "/zero", bytes: Data())
            try FileManager.default.createDirectory(at: tree.url(folder + "/empty"), withIntermediateDirectories: true)
        }
        try tree.write("Loose.bin", bytes: large)
        let index = try await scan(tree)
        let result = try await DuplicateFinder.find(in: index, minimumSize: 100_000)
        #expect(result.revision == (await index.revision))
        let folder = try #require(result.folderSets.first)
        #expect(result.folderSets.count == 1)
        #expect(folder.folders.map(\.name) == ["Projects backup", "Projects", "Old projects"])
        #expect(folder.fileCount == 4)
        for member in folder.folders {
            #expect(folder.files(in: member).map(\.name) == ["Large.bin", "Other.bin", "Small.txt", "zero"])
        }
        let external = try #require(result.sets.first)
        #expect(result.sets.count == 1)
        #expect(external.files.count == 4)
        #expect(external.relatedFolderIDs == [folder.id])
        #expect(external.files.contains { $0.name == "Loose.bin" })
        #expect(try await DuplicateFinder.find(in: index, minimumSize: 100_000) == result)

        let capped = try await DuplicateFinder.find(in: index, minimumSize: 100_000, folderEntryLimit: 1)
        #expect(capped.folderLimitExceeded)
        #expect(capped.folderSets.isEmpty && capped.sets.count == 2)
        await close(index)
    }

    @Test(arguments: ["small data", "empty folder", "zero name", "summary", "package", "partial"])
    func nearMatchesKeepTheirFileRows(_ difference: String) async throws {
        let tree = try emptyTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let large = Data(repeating: 19, count: 100_000)
        for folder in ["A", "B"] {
            try tree.write(folder + "/large.bin", bytes: large)
            try tree.write(folder + "/Nested/small", bytes: Data((folder == "B" && difference == "small data" ? "else" : "same").utf8))
            try tree.write(folder + (folder == "B" && difference == "zero name" ? "/other-zero" : "/zero"), bytes: Data())
            if folder == "A" || difference != "empty folder" {
                try FileManager.default.createDirectory(at: tree.url(folder + "/empty"), withIntermediateDirectories: true)
            }
            if difference == "summary" { try tree.write(folder + "/node_modules/file", bytes: Data([1])) }
            if difference == "package" {
                let package = folder + "/Test.app"
                try tree.write(package + "/Contents/file", bytes: Data([1]))
                // kHasBundle in the Finder flags makes package detection deterministic.
                var finderInfo = [UInt8](repeating: 0, count: 32)
                finderInfo[8] = 0x20
                let status = finderInfo.withUnsafeBytes {
                    setxattr(tree.url(package).path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0)
                }
                try #require(status == 0)
            }
        }
        let index = try await scan(tree)
        if difference == "partial" {
            await index.issue(path: tree.url("B/Nested").path, message: "Generated read failure")
            try await index.aggregate()
        }
        let result = try await DuplicateFinder.find(in: index, minimumSize: 100_000)
        #expect(result.folderSets.isEmpty)
        #expect(result.sets.count == 1 && result.sets[0].files.count == 2)
        await close(index)
    }

    @Test func eligibleAliasRepresentsItsInodeAndChangedFilesAreCountedOnce() async throws {
        let tree = try emptyTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let bytes = Data(repeating: 64, count: 130_000)
        try tree.write("a", bytes: bytes)
        try FileManager.default.linkItem(at: tree.url("a"), to: tree.url("b"))
        try tree.write("independent", bytes: bytes)
        try tree.write("changed", bytes: bytes)
        let index = try await scan(tree)
        let a = try #require(await index.node(path: tree.url("a").path))
        let countedName = a.knownLogicalSize > 0 ? "a" : "b"
        let aliasName = countedName == "a" ? "b" : "a"
        try tree.write("changed", bytes: Data(repeating: 65, count: bytes.count))
        let result = try await DuplicateFinder.find(in: index, minimumSize: 100_000, eligible: { $0.name != countedName })
        #expect(result.unreadable == 1)
        let match = try #require(result.sets.first)
        #expect(match.files.map(\.name) == [aliasName, "independent"])
        #expect(match.files.first?.knownAllocatedSize == 0)
        await close(index)
    }

    @Test(arguments: [false, true])
    func cancellationIsCheckedInsidePrefixAndFullReads(_ fullRead: Bool) throws {
        let tree = try emptyTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let size = DuplicateIO.chunkSize * 2
        try tree.write("file", bytes: Data(repeating: 66, count: size))
        let info = try FileIdentity.read(tree.url("file"))
        let node = FileNode(id: 1, parentID: nil, path: tree.url("file").path, name: "file", isDirectory: false,
                            logicalSize: Int64(size), allocatedSize: nil, modified: info.modified,
                            identity: info.identity, fingerprint: info.fingerprint)
        var buffer = [UInt8](repeating: 0, count: DuplicateIO.chunkSize)
        var checkpoints = 0
        #expect(throws: CancellationError.self) {
            try DuplicateIO.read(DuplicateCandidate(node: node, size: Int64(size)),
                                 limit: fullRead ? nil : DuplicateFinder.prefixBytes, buffer: &buffer) {
                checkpoints += 1
                if checkpoints == 3 { throw CancellationError() }
            }
        }
    }

    @Test func workerObservesCallerCancellationAndRevisionMustStayCurrent() async throws {
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            defer { continuation.finish() }
            try await DuplicateIO.run { cancellation in
                continuation.yield(())
                _ = release.wait(timeout: .now() + .seconds(5))
                try cancellation.check()
            }
        }
        var started = false
        for await _ in entered { started = true; break }
        try #require(started)
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }

        let tree = try emptyTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let index = try await scan(tree)
        let revision = await index.revision
        try await index.aggregate()
        await #expect(throws: DuplicateSearchError.self) { try await index.validateDuplicateRevision(revision) }
        await close(index)
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
        await close(index)

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
        await close(index2)
    }
}
