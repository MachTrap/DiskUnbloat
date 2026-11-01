import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Queue-tree projection and lazy expansion: the panel's compact selected-first hierarchy.
@MainActor struct CleanupQueueTests {
    private func node(_ id: Int64, _ parent: Int64?, _ path: String, dir: Bool, size: Int64 = 0) -> FileNode {
        FileNode(id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                 isDirectory: dir, logicalSize: size, allocatedSize: size, modified: nil, identity: "\(id)",
                 knownLogicalSize: size, knownAllocatedSize: size)
    }

    /// Stub provider over an in-memory tree; children come back name-sorted and paged.
    private struct StubQueueProvider: CleanupQueueProviding {
        let nodes: [Int64: FileNode]
        let childrenByID: [Int64: [FileNode]]
        func node(id: Int64) async -> FileNode? { nodes[id] }
        func children(of parentID: Int64, limit: Int, offset: Int) async -> [FileNode] {
            let all = (childrenByID[parentID] ?? []).sorted { $0.name < $1.name }
            guard offset < all.count else { return [] }
            return Array(all[offset..<min(offset + limit, all.count)])
        }
        func childCount(of parentID: Int64) async -> Int { (childrenByID[parentID] ?? []).count }
    }

    /// root(1) has folder(2), b(4), c(5); folder has a.bin(3), file.bin(6).
    private func fixture() -> (nodes: [Int64: FileNode], children: [Int64: [FileNode]]) {
        let root = node(1, nil, "/Users/xqueue/t", dir: true, size: 100)
        let folder = node(2, 1, "/Users/xqueue/t/folder", dir: true, size: 40)
        let a = node(3, 2, "/Users/xqueue/t/folder/a.bin", dir: false, size: 10)
        let file = node(6, 2, "/Users/xqueue/t/folder/file.bin", dir: false, size: 30)
        let b = node(4, 1, "/Users/xqueue/t/b.bin", dir: false, size: 25)
        let c = node(5, 1, "/Users/xqueue/t/c.bin", dir: false, size: 35)
        let nodes: [Int64: FileNode] = [root, folder, a, file, b, c].reduce(into: [:]) { $0[$1.id] = $1 }
        let children: [Int64: [FileNode]] = [1: [folder, b, c], 2: [a, file]]
        return (nodes, children)
    }

    @Test func wholeFolderSelectionIsOneAtomicCheckedRow() {
        let (nodes, _) = fixture()
        let entries = [CleanupEntry(node: nodes[2]!, operation: .remove)]
        let lines = CleanupQueueTree.lines(.init(entries: entries, nodes: nodes, childCounts: [1: 3]))
        // A fully selected folder is atomic: its contents disappear with it, so no child
        // rows and no hidden-sibling controls appear for the folder itself. The root's
        // unselected siblings remain behind their own expander.
        #expect(lines.map(\.id) == ["item-1", "item-2", "more-1"])
        guard case .item(let rootRow) = lines[0], case .item(let folderRow) = lines[1] else {
            Issue.record("Expected root context row and one atomic folder row"); return
        }
        #expect(rootRow.checkState == .partial && rootRow.hasSelectedDescendants && rootRow.hiddenChildCount == 2)
        #expect(folderRow.checkState == .checked && folderRow.operation == .remove)
        #expect(folderRow.bytes == 40 && !folderRow.hasHiddenChildren && !folderRow.hasSelectedDescendants)
    }

    @Test func partialSelectionExpandsWithSelectedChildrenFirst() {
        let (nodes, _) = fixture()
        // Only folder/a.bin is selected inside folder; unselected siblings stay hidden.
        let entries = [CleanupEntry(node: nodes[3]!, operation: .remove)]
        let lines = CleanupQueueTree.lines(.init(entries: entries, nodes: nodes, childCounts: [1: 3, 2: 2]))
        #expect(lines.map(\.id) == ["item-1", "item-2", "item-3", "more-2", "more-1"])
        guard case .item(let rootRow) = lines[0], case .item(let folderRow) = lines[1], case .item(let aRow) = lines[2] else {
            Issue.record("Expected root, folder, then selected child"); return
        }
        #expect(rootRow.checkState == .partial && rootRow.hasSelectedDescendants)
        #expect(folderRow.checkState == .partial && folderRow.hiddenChildCount == 1)
        #expect(aRow.checkState == .checked && aRow.node.id == 3)
        // Partial rows contribute only the selected bytes, never the whole subtree.
        #expect(rootRow.bytes == 10 && folderRow.bytes == 10)
    }

    @Test func revealedSiblingsFollowSelectedItemsAndPagingRemains() {
        let (nodes, children) = fixture()
        let entries = [CleanupEntry(node: nodes[3]!, operation: .remove)]
        let lines = CleanupQueueTree.lines(.init(
            entries: entries, nodes: nodes, childCounts: [1: 3, 2: 3],
            fetchedChildren: [2: children[2]!], revealed: ["/Users/xqueue/t/folder"]))
        // Selected item first, then the revealed unselected sibling, then pagination for
        // the rest; hidden root siblings stay hidden behind their own expander.
        #expect(lines.map(\.id) == ["item-1", "item-2", "item-3", "item-6", "showMore-2", "more-1"])
        guard case .item(let sibling) = lines[3] else { Issue.record("Expected revealed sibling"); return }
        #expect(sibling.checkState == .unchecked && sibling.node.id == 6 && sibling.bytes == 30)
    }

    @Test func collapsedFoldersHideTheirSelectedChildren() {
        let (nodes, _) = fixture()
        let entries = [CleanupEntry(node: nodes[3]!, operation: .remove)]
        let lines = CleanupQueueTree.lines(.init(
            entries: entries, nodes: nodes, childCounts: [2: 2], collapsed: ["/Users/xqueue/t/folder"]))
        #expect(lines.map(\.id) == ["item-1", "item-2"])
    }

    @Test func syntheticGroupWrapperNeverBecomesARow() {
        let (nodes, _) = fixture()
        let wrapper = node(100, nil, ScanGroup.path, dir: true)
        let root = nodes[1]!
        var adjusted = nodes
        adjusted[1] = FileNode(id: 1, parentID: 100, path: root.path, name: root.name, isDirectory: true,
                               logicalSize: 100, allocatedSize: 100, modified: nil, identity: "1",
                               knownLogicalSize: 100, knownAllocatedSize: 100)
        adjusted[100] = wrapper
        let entries = [CleanupEntry(node: adjusted[2]!, operation: .remove)]
        let lines = CleanupQueueTree.lines(.init(entries: entries, nodes: adjusted, childCounts: [2: 2]))
        // The real root is the top-level row; the synthetic wrapper is skipped entirely.
        #expect(lines.map(\.id) == ["item-1", "item-2"])
        #expect(lines.contains { line in
            if case .item(let row) = line { return row.node.isGroupRoot }
            return false
        } == false)
    }

    @Test func queueTotalsUseNormalizedEntriesOnce() {
        let service = RecordingCleanupService()
        let cleanup = CleanupViewModel(service: service, homePath: "/Users/xqueue")
        let root = URL(fileURLWithPath: "/Users/xqueue")
        let (nodes, _) = fixture()
        #expect(cleanup.add(nodes[3]!, root: root) == nil)
        #expect(cleanup.add(nodes[2]!, root: root) == nil)
        // The folder entry subsumes the earlier file entry; totals count it once.
        #expect(cleanup.basket.map(\.node.id) == [2])
        #expect(cleanup.estimatedBytes == 40)
        #expect(cleanup.queueRevision == 2)
    }

    @Test func membershipDistinguishesCoveringAndCoveredPaths() {
        #expect(queueMembership(path: "/t/folder/a", queuedPaths: ["/t/folder"]) == .insideSelection)
        #expect(queueMembership(path: "/t/folder", queuedPaths: ["/t/folder/a"]) == .containsSelection)
        #expect(queueMembership(path: "/t/folder", queuedPaths: ["/t/folder"]) == .selected)
        #expect(queueMembership(path: "/t/other", queuedPaths: ["/t/folder"]) == .none)
    }

    @Test func modelGathersAncestorsAndLazySiblings() async throws {
        let (nodes, children) = fixture()
        let service = RecordingCleanupService()
        let cleanup = CleanupViewModel(service: service, homePath: "/Users/xqueue")
        cleanup.basket = [CleanupEntry(node: nodes[3]!, operation: .remove)]
        let model = CleanupQueueModel(cleanup: cleanup)
        model.attach(StubQueueProvider(nodes: nodes, childrenByID: children))
        await model.refresh()
        #expect(model.lines.map(\.id) == ["item-1", "item-2", "item-3", "more-2", "more-1"])
        // Revealing loads one page of unselected siblings lazily.
        model.toggleRevealed(nodes[2]!)
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.lines.map(\.id) == ["item-1", "item-2", "item-3", "item-6", "more-1"])
        // Emptying the queue empties the tree.
        cleanup.basket = []
        await model.refresh()
        #expect(model.lines.isEmpty)
    }

    @Test func deselectRemovesEveryOverlappingEntry() {
        let service = RecordingCleanupService()
        let cleanup = CleanupViewModel(service: service, homePath: "/Users/xqueue")
        let (nodes, _) = fixture()
        cleanup.basket = [
            CleanupEntry(node: nodes[3]!, operation: .remove),
            CleanupEntry(node: nodes[4]!, operation: .remove)
        ]
        cleanup.deselect(nodes[2]!)
        #expect(cleanup.basket.map(\.node.id) == [4])
        cleanup.deselect(nodes[4]!)
        #expect(cleanup.basket.isEmpty)
    }
}
