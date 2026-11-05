import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct DuplicateCommitTests {
    @Test func keepsRecommendationsAndProtectsTheReviewedPairAcrossLaterEdits() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), activity: FixedActivity(paths: []))
        let original = try await fixture.node("recommendation")
        let manual = try await fixture.node("manual")
        let copy = try await fixture.node("Copies/copy")
        let keeper = try await fixture.node("Kept/keep")
        let folder = try await fixture.node("Copies")
        let keepFolder = try await fixture.node("Kept")
        let rootNode = try #require(await fixture.index.node(path: fixture.root.path))
        let guarded = CleanupEntry(node: copy, operation: .remove, survivor: .init(keeper))
        func recommendation(_ nodes: [FileNode]) -> AutoSelectionResult {
            AutoSelectionResult(groups: [.init(location: rootNode, nodes: nodes, coversAllChildren: false)])
        }
        #expect(cleanup.add(manual, roots: fixture.roots) == nil)
        #expect(cleanup.applyAutoSelection(recommendation([original]), roots: fixture.roots).applied == 1)
        let commit = await cleanup.commitReviewedDuplicates([guarded], roots: fixture.roots, index: fixture.index) { true }
        #expect(commit.succeeded && commit.added == 1 && commit.alreadyQueued == 0 && cleanup.showQueue)
        #expect(Set(cleanup.basket.map(\.node.path)) == [original.path, manual.path, copy.path])
        let repeated = await cleanup.commitReviewedDuplicates([guarded], roots: fixture.roots, index: fixture.index) { true }
        #expect(repeated.succeeded && repeated.added == 0 && repeated.alreadyQueued == 1)
        #expect(cleanup.addOrClear(folder, roots: fixture.roots) != nil)
        #expect(cleanup.add(keeper, roots: fixture.roots) != nil)
        #expect(cleanup.add(copy, roots: fixture.roots) != nil)
        let result = cleanup.applyAutoSelection(recommendation([folder, keepFolder]), roots: fixture.roots)
        #expect(result.applied == 0 && result.skipped == 2)
        #expect(cleanup.basket.contains(guarded) && cleanup.basket.contains { $0.node.path == manual.path })
        #expect(cleanup.invalidate(overlapping: keepFolder.path) == 1)
        #expect(cleanup.basket.map(\.node.path) == [manual.path])
        await fixture.index.close()
    }

    @Test func conflictsAndConcurrentEditsLeaveTheBatchUnapplied() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), activity: FixedActivity(paths: []))
        let copy = try await fixture.node("Copies/copy")
        let second = try await fixture.node("Copies/second")
        let keeper = try await fixture.node("Kept/keep")
        let folder = try await fixture.node("Copies")
        let manual = try await fixture.node("manual")
        let guarded = CleanupEntry(node: copy, operation: .remove, survivor: .init(keeper))
        let other = CleanupEntry(node: second, operation: .remove, survivor: .init(keeper))
        #expect(cleanup.add(copy, roots: fixture.roots) == nil)
        let conflict = await cleanup.commitReviewedDuplicates([guarded, other], roots: fixture.roots, index: fixture.index) { true }
        #expect(!conflict.succeeded && conflict.refusals.map(\.path) == [copy.path])
        #expect(cleanup.basket.map(\.node.path) == [copy.path] && cleanup.basket.first?.survivor == nil)
        cleanup.clearSelection()
        #expect(cleanup.add(folder, roots: fixture.roots) == nil)
        let covering = await cleanup.commitReviewedDuplicates([guarded, other], roots: fixture.roots, index: fixture.index) { true }
        #expect(!covering.succeeded && covering.refusals.count == 2)
        #expect(cleanup.basket.map(\.node.path) == [folder.path])
        cleanup.clearSelection()
        let concurrent = await cleanup.commitReviewedDuplicates([guarded, other], roots: fixture.roots, index: fixture.index) {
            #expect(cleanup.add(manual, roots: fixture.roots) == nil)
            return true
        }
        #expect(!concurrent.succeeded && cleanup.basket.map(\.node.path) == [manual.path])
        await fixture.index.close()
    }

    private struct Fixture {
        let root: URL
        let index: ScanIndex
        var roots: [URL] { [root] }

        init() async throws {
            let fm = FileManager.default
            root = canonicalURL(fm.temporaryDirectory).appendingPathComponent(UUID().uuidString, isDirectory: true)
            for path in ["Copies/copy", "Copies/second", "Kept/keep", "manual", "recommendation"] {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("test".utf8).write(to: url)
            }
            index = try ScanIndex(url: root.appendingPathComponent("index.sqlite"))
            for await _ in await ScanCoordinator().scan(ScanRequest(root: root), into: index) {}
        }

        func node(_ path: String) async throws -> FileNode {
            try #require(await index.node(path: root.appendingPathComponent(path).path))
        }

        func dispose() { try? FileManager.default.removeItem(at: root) }
    }
}
