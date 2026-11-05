import Foundation
import Testing
@testable import DiskCore

struct DuplicateCleanupTests {
    private let fm = FileManager.default

    private func fixture() throws -> URL {
        let root = canonicalURL(fm.temporaryDirectory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        for path in ["A/inner/file", "A-backup/extra", "Keep/file", "unrelated"] {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        return root
    }

    private func scan(_ root: URL) async throws -> ScanIndex {
        let index = try ScanIndex(url: root.appendingPathComponent("index.sqlite"))
        for await _ in await ScanCoordinator().scan(ScanRequest(root: root), into: index) {}
        return index
    }

    @Test func exactGuardSurvivesNormalizationAndCoveringConflictsFailTheWholePlan() async throws {
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let index = try await scan(root)
        func node(_ relativePath: String) async throws -> FileNode {
            try #require(await index.node(path: root.appendingPathComponent(relativePath).path))
        }
        let copy = try await node("A/inner/file")
        let keeper = try await node("Keep/file")
        let guarded = CleanupEntry(node: copy, operation: .remove, survivor: .init(keeper))
        let identical = CleanupPlan(roots: [root], entries: [guarded, guarded], mode: .permanent)
        #expect(identical.items == [guarded])
        #expect(identical.duplicateRefusals.isEmpty)
        let ordinary = CleanupEntry(node: copy, operation: .remove)
        let exactConflict = CleanupPlan(roots: [root], entries: [guarded, ordinary], mode: .permanent)
        #expect(exactConflict.items == [guarded])
        #expect(exactConflict.duplicateRefusals[copy.path] == .conflictingSelection)

        let ancestor = try await node("A")
        let inner = try await node("A/inner")
        let adjacent = try await node("A-backup")
        let unrelated = try await node("unrelated")
        let plan = CleanupPlan(roots: [root], entries: [
            CleanupEntry(node: ancestor, operation: .emptyContents),
            CleanupEntry(node: inner, operation: .remove),
            CleanupEntry(node: adjacent, operation: .remove),
            CleanupEntry(node: unrelated, operation: .remove),
            guarded
        ], mode: .permanent)
        #expect(plan.items.map(\.node.path) == [ancestor.path, adjacent.path, unrelated.path])
        #expect(plan.duplicateRefusals[ancestor.path] == .conflictingSelection)
        #expect(plan.duplicateRefusals[inner.path] == .conflictingSelection)
        let refused = await CleanupService().execute(plan)
        #expect(refused.count == 3 && refused.allSatisfy { !$0.succeeded })
        #expect(fm.fileExists(atPath: copy.path) && fm.fileExists(atPath: unrelated.path))

        let keepFolder = try await node("Keep")
        let queuedKeeper = CleanupPlan(roots: [root], entries: [
            guarded, CleanupEntry(node: keepFolder, operation: .emptyContents)
        ], mode: .permanent)
        #expect(queuedKeeper.duplicateRefusals[copy.path] == .keeperSelected)
        #expect(queuedKeeper.duplicateRefusals[keepFolder.path] == .keeperSelected)
        #expect(await CleanupService().execute(queuedKeeper).allSatisfy { !$0.succeeded })
        #expect(fm.fileExists(atPath: keeper.path))

        let ancestors = await index.cleanupAncestorIdentities(for: [guarded])
        let valid = CleanupPlan(roots: [root], entries: [guarded, guarded], mode: .permanent, ancestorIdentities: ancestors)
        #expect(await CleanupService().execute(valid).first?.succeeded == true)
        #expect(fm.fileExists(atPath: keeper.path))
        #expect(!fm.fileExists(atPath: copy.path))
        await index.close()
    }

    @Test func refusesReplacedKeeperAncestorEvenWithTheSameFile() async throws {
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let keeperURL = root.appendingPathComponent("Keep/file")
        let alternate = root.appendingPathComponent("alternate")
        try fm.createDirectory(at: alternate, withIntermediateDirectories: true)
        try fm.linkItem(at: keeperURL, to: alternate.appendingPathComponent("file"))
        let index = try await scan(root)
        let keeper = try #require(await index.node(path: keeperURL.path))
        let copy = try #require(await index.node(path: root.appendingPathComponent("A/inner/file").path))
        let entry = CleanupEntry(node: copy, operation: .remove, survivor: .init(keeper))
        let ancestors = await index.cleanupAncestorIdentities(for: [entry])
        #expect(ancestors[keeperURL.deletingLastPathComponent().path] != nil)
        let before = await CleanupService.validateReviewedDuplicates([entry], roots: [root], index: index)
        #expect(before.isEmpty)
        try fm.moveItem(at: keeperURL.deletingLastPathComponent(), to: root.appendingPathComponent("parked"))
        try fm.moveItem(at: alternate, to: keeperURL.deletingLastPathComponent())
        let live = try FileIdentity.read(keeperURL)
        #expect(live.identity == keeper.identity && live.fingerprint == keeper.fingerprint)
        let after = await CleanupService.validateReviewedDuplicates([entry], roots: [root], index: index)
        #expect(after[copy.path] == .ancestryChanged)
        let plan = CleanupPlan(roots: [root], entries: [entry], mode: .permanent, ancestorIdentities: ancestors)
        #expect(await CleanupService().execute(plan).first?.message == DuplicateCleanupRefusal.ancestryChanged.message)
        #expect(fm.fileExists(atPath: copy.path))
        await index.close()
    }
}
