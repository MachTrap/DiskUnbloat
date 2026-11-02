import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Two-tier automatic selection at the queue level: bulk apply replaces the previous
/// recommendation while manual picks survive, refusals are counted instead of forced,
/// and fully covered scan roots collapse to one emptied entry.
@MainActor struct AutoSelectionTests {
    private let home = "/Users/autoapply"

    private func node(_ id: Int64, _ parent: Int64?, _ path: String, dir: Bool = true, size: Int64 = 1024) -> FileNode {
        FileNode(id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                 isDirectory: dir, logicalSize: size, allocatedSize: size, modified: Date(), identity: "\(id)",
                 knownLogicalSize: size, knownAllocatedSize: size)
    }

    @Test func recommendationReplacesItsPreviousSelectionAndKeepsManualPicks() {
        let cleanup = CleanupViewModel(service: SucceedingCleanupService(), homePath: home, activity: FixedActivity(paths: []))
        let roots = [URL(fileURLWithPath: home)]
        let manual = node(10, 1, home + "/Documents/keep.zip", dir: false)
        #expect(cleanup.add(manual, roots: roots) == nil)
        let a = node(2, 1, home + "/lib/a")
        let b = node(3, 1, home + "/lib/b")
        let first = AutoSelectionResult(groups: [AutoSelectionGroup(location: node(1, nil, home + "/lib"), nodes: [a], coversAllChildren: false)])
        let second = AutoSelectionResult(groups: [AutoSelectionGroup(location: node(1, nil, home + "/lib"), nodes: [b], coversAllChildren: false)])
        let outcome = cleanup.applyAutoSelection(first, roots: roots)
        #expect(outcome == AutoSelectionApplyOutcome(applied: 1, skipped: 0))
        #expect(Set(cleanup.basket.map { $0.node.path }) == [manual.path, a.path])
        // Unchecking a recommendation item, then re-clicking, re-applies it cleanly.
        cleanup.deselect(a)
        #expect(Set(cleanup.basket.map { $0.node.path }) == [manual.path])
        _ = cleanup.applyAutoSelection(first, roots: roots)
        #expect(Set(cleanup.basket.map { $0.node.path }) == [manual.path, a.path])
        // A fresh recommendation replaces the previous one; the manual pick stays.
        _ = cleanup.applyAutoSelection(second, roots: roots)
        #expect(Set(cleanup.basket.map { $0.node.path }) == [manual.path, b.path])
    }

    @Test func refusedItemsAreCountedNeverForced() {
        let active = home + "/Library/Caches/com.running.app"
        let cleanup = CleanupViewModel(service: SucceedingCleanupService(), homePath: home, activity: FixedActivity(paths: [active]))
        let roots = [URL(fileURLWithPath: home)]
        let blocked = node(2, 1, active + "/cache.db", dir: false)
        let fine = node(3, 1, home + "/lib/a")
        let result = AutoSelectionResult(groups: [AutoSelectionGroup(
            location: node(1, nil, home + "/lib"), nodes: [blocked, fine], coversAllChildren: false)])
        let outcome = cleanup.applyAutoSelection(result, roots: roots)
        #expect(outcome == AutoSelectionApplyOutcome(applied: 1, skipped: 1))
        #expect(cleanup.basket.map { $0.node.path } == [fine.path])
    }

    @Test func fullyCoveredScanRootBecomesOneEmptiedEntry() throws {
        let derived = home + "/Library/Developer/Xcode/DerivedData"
        let cleanup = CleanupViewModel(service: SucceedingCleanupService(), homePath: home, activity: FixedActivity(paths: []))
        // Grouped scans list several roots; the covered one collapses to "keep folder".
        let roots = [URL(fileURLWithPath: derived), URL(fileURLWithPath: home)]
        let location = node(1, nil, derived)
        let childA = node(2, 1, derived + "/BuildA")
        let childB = node(3, 1, derived + "/BuildB")
        let result = AutoSelectionResult(groups: [AutoSelectionGroup(location: location, nodes: [childA, childB], coversAllChildren: true)])
        let outcome = cleanup.applyAutoSelection(result, roots: roots)
        #expect(outcome == AutoSelectionApplyOutcome(applied: 1, skipped: 0))
        #expect(cleanup.basket.count == 1)
        let entry = try #require(cleanup.basket.first)
        #expect(entry.node.path == derived)
        #expect(entry.operation == .emptyContents)
    }

    @Test func bulkApplyNormalizesALargeRecommendation() {
        let cleanup = CleanupViewModel(service: SucceedingCleanupService(), homePath: home, activity: FixedActivity(paths: []))
        let roots = [URL(fileURLWithPath: home)]
        let location = node(1, nil, home + "/Library/Caches")
        let children = (2...2001).map { node(Int64($0), 1, home + "/Library/Caches/item\($0)") }
        let result = AutoSelectionResult(groups: [AutoSelectionGroup(location: location, nodes: children, coversAllChildren: true)])
        let outcome = cleanup.applyAutoSelection(result, roots: roots)
        // The container is not a scan root here: its children queue individually.
        #expect(outcome.applied == 2000 && outcome.skipped == 0)
        #expect(cleanup.basket.count == 2000)
        #expect(cleanup.basket.allSatisfy { $0.operation == .remove })
    }

    @Test func coveredContainersRenderAsOneAtomicKeptFolderRow() {
        let folder = node(1, nil, "/Users/rows/t", dir: true, size: 100)
        let a = node(2, 1, "/Users/rows/t/a", size: 40)
        let b = node(3, 1, "/Users/rows/t/b", size: 60)
        let nodes = [folder, a, b].reduce(into: [Int64: FileNode]()) { $0[$1.id] = $1 }
        let entries = [CleanupEntry(node: a, operation: .remove), CleanupEntry(node: b, operation: .remove)]
        // Every child queued: one checked row, "keeps folder", no nested rows.
        let covered = CleanupQueueTree.lines(.init(
            entries: entries, nodes: nodes, current: nil, childCounts: [1: 2]))
        #expect(covered.count == 1)
        guard case .item(let row) = covered[0] else { Issue.record("Expected one row"); return }
        #expect(row.checkState == .checked && row.coversAllChildren && row.keepsFolder)
        #expect(row.bytes == 100)
        // One child left unselected: the folder goes back to a partial row with the
        // unselected sibling behind its hidden-items row.
        let partial = CleanupQueueTree.lines(.init(
            entries: [entries[0]], nodes: nodes, current: nil, childCounts: [1: 2]))
        #expect(partial.count == 3)
        guard case .item(let folderRow) = partial[0], case .item(let childRow) = partial[1] else {
            Issue.record("Expected a partial folder row with its selected child"); return
        }
        #expect(folderRow.checkState == .partial && !folderRow.coversAllChildren && !folderRow.keepsFolder)
        #expect(folderRow.bytes == 40 && childRow.node.id == 2)
    }

    @Test func emptyRecommendationPostsANoticeInsteadOfSelecting() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready(); await scanner.finish(); await model.waitForScan()
        // The fixture scan contains no curated locations: nothing is recommended.
        let preview = await model.previewSelection(.safe)
        #expect(preview == nil)
        #expect(model.message == L10n.text("Nothing recommended in this scan."))
        #expect(model.cleanup.basket.isEmpty)
        await model.shutdown()
    }

    @Test func longUnusedThresholdPersistsAcrossLaunches() throws {
        let name = "AutoSelectionTests-" + UUID().uuidString
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let scanner = ControlledScanner()
        let fresh = ScanViewModel(coordinator: scanner, defaults: suite)
        #expect(fresh.options.longUnusedDays == 90)
        fresh.options.longUnusedDays = 33
        #expect(suite.object(forKey: "longUnusedDays") as? Int == 33)
        let relaunched = ScanViewModel(coordinator: scanner, defaults: suite)
        #expect(relaunched.options.longUnusedDays == 33)
    }
}
