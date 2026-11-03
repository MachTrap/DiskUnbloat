import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Queue-tree projection and lazy expansion: the panel's current-folder listing and
/// compact selected-first hierarchy.
@MainActor struct CleanupQueueTests {
    private func node(_ id: Int64, _ parent: Int64?, _ path: String, dir: Bool, size: Int64 = 0) -> FileNode {
        FileNode(id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                 isDirectory: dir, logicalSize: size, allocatedSize: size, modified: nil, identity: "\(id)",
                 knownLogicalSize: size, knownAllocatedSize: size)
    }

    /// Stub provider over an in-memory tree; children come back paged in the requested
    /// order (by name, or by known size descending).
    private struct StubQueueProvider: CleanupQueueProviding {
        let nodes: [Int64: FileNode]
        let childrenByID: [Int64: [FileNode]]
        func node(id: Int64) async -> FileNode? { nodes[id] }
        func children(of parentID: Int64, limit: Int, offset: Int, sortByName: Bool) async -> [FileNode] {
            let all = (childrenByID[parentID] ?? []).sorted { a, b in
                if sortByName { return a.name < b.name }
                let left = a.knownSize(for: .allocated)
                let right = b.knownSize(for: .allocated)
                return left == right ? a.path < b.path : left > right
            }
            guard offset < all.count else { return [] }
            return Array(all[offset..<min(offset + limit, all.count)])
        }
        func childCount(of parentID: Int64) async -> Int { (childrenByID[parentID] ?? []).count }
        func ancestors(of ids: [Int64]) async -> [Int64: FileNode] {
            var result: [Int64: FileNode] = [:]
            var frontier = Set(ids)
            while !frontier.isEmpty {
                for id in frontier where nodes[id] != nil { result[id] = nodes[id]! }
                var next = Set<Int64>()
                for id in frontier {
                    if let parentID = nodes[id]?.parentID, result[parentID] == nil { next.insert(parentID) }
                }
                frontier = next
            }
            return result
        }
        func childCounts(of ids: [Int64]) async -> [Int64: Int] {
            ids.reduce(into: [:]) { $0[$1] = (childrenByID[$1] ?? []).count }
        }
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

    @Test func currentFolderListsChildrenBySizeDescending() {
        let (nodes, children) = fixture()
        // Nothing is selected: the panel still lists the open folder, largest first.
        let lines = CleanupQueueTree.lines(.init(
            entries: [], nodes: nodes, current: nodes[1],
            directoryChildren: children[1]!.sorted { $0.knownSize(for: .allocated) > $1.knownSize(for: .allocated) },
            directoryCount: 3))
        #expect(lines.map(\.id) == ["header-1", "item-2", "item-5", "item-4"])
        guard case .directoryHeader(let open) = lines[0], case .item(let folderRow) = lines[1],
              case .item(let cRow) = lines[2], case .item(let bRow) = lines[3] else {
            Issue.record("Expected a header, then size-ordered children"); return
        }
        #expect(open.id == 1)
        #expect(folderRow.checkState == .unchecked && folderRow.node.id == 2 && folderRow.bytes == 40)
        #expect(cRow.node.id == 5 && cRow.bytes == 35)
        #expect(bRow.node.id == 4 && bRow.bytes == 25)
    }

    @Test func selectedDirectChildShowsCheckedInsideTheListing() {
        let (nodes, children) = fixture()
        // A selected direct child belongs in the listing as a checked row, not twice.
        let entries = [CleanupEntry(node: nodes[4]!, operation: .remove)]
        let lines = CleanupQueueTree.lines(.init(
            entries: entries, nodes: nodes, current: nodes[1],
            directoryChildren: children[1]!.sorted { $0.knownSize(for: .allocated) > $1.knownSize(for: .allocated) },
            directoryCount: 3))
        #expect(lines.map(\.id) == ["header-1", "item-2", "item-5", "item-4"])
        guard case .item(let bRow) = lines[3] else { Issue.record("Expected the selected child in the listing"); return }
        #expect(bRow.checkState == .checked && bRow.operation == .remove && bRow.bytes == 25)
    }

    @Test func deepSelectionNestsUnderItsListingRow() {
        let (nodes, children) = fixture()
        // A file selected below a listing folder nests under that folder's row.
        let entries = [CleanupEntry(node: nodes[6]!, operation: .remove)]
        let lines = CleanupQueueTree.lines(.init(
            entries: entries, nodes: nodes, current: nodes[1],
            directoryChildren: children[1]!.sorted { $0.knownSize(for: .allocated) > $1.knownSize(for: .allocated) },
            directoryCount: 3))
        #expect(lines.map(\.id) == ["header-1", "item-2", "item-6", "item-5", "item-4"])
        guard case .item(let folderRow) = lines[1], case .item(let fileRow) = lines[2] else {
            Issue.record("Expected the partial folder then its selected child"); return
        }
        #expect(folderRow.checkState == .partial && folderRow.bytes == 30)
        // A partially selected folder shows selected over the folder's total.
        #expect(folderRow.totalBytes == 40)
        #expect(fileRow.checkState == .checked && fileRow.node.id == 6 && fileRow.depth == 1)
    }

    @Test func directoryListingPaginatesWithHonestCount() {
        let (nodes, children) = fixture()
        let lines = CleanupQueueTree.lines(.init(
            entries: [], nodes: nodes, current: nodes[1],
            directoryChildren: children[1]!.sorted { $0.knownSize(for: .allocated) > $1.knownSize(for: .allocated) },
            directoryCount: 5))
        #expect(lines.map(\.id) == ["header-1", "item-2", "item-5", "item-4", "showMore-1"])
    }

    /// root(1) contains box(10) with five files: 11..15 sized 500, 400, 300, 200, 100.
    private func boxFixture() -> (nodes: [Int64: FileNode], children: [Int64: [FileNode]]) {
        let root = node(1, nil, "/t2", dir: true, size: 100)
        let box = node(10, 1, "/t2/box", dir: true, size: 1500)
        var nodes: [Int64: FileNode] = [1: root, 10: box]
        let sizes: [(Int64, Int64)] = [(11, 500), (12, 400), (13, 300), (14, 200), (15, 100)]
        var kids: [FileNode] = []
        for (id, size) in sizes {
            let f = node(id, 10, "/t2/box/f\(id).bin", dir: false, size: size)
            nodes[id] = f; kids.append(f)
        }
        return (nodes, [1: [box], 10: kids])
    }

    @Test func unselectedContainersAreExpandable() {
        let (nodes, children) = boxFixture()
        let lines = CleanupQueueTree.lines(.init(
            entries: [], nodes: nodes, current: nodes[1],
            directoryChildren: children[1]!, directoryCount: 1))
        // A container with nothing selected still offers a chevron; nothing nested shows
        // until the user expands it.
        #expect(lines.map(\.id) == ["header-1", "item-10"])
        guard case .item(let boxRow) = lines[1] else { Issue.record("Expected the container row"); return }
        #expect(boxRow.canPeek && boxRow.checkState == .unchecked && !boxRow.hasSelectedDescendants)
    }

    @Test func peekShowsThreeLargestThenPaging() {
        let (nodes, children) = boxFixture()
        let largest3 = children[10]!.sorted { $0.knownSize(for: .allocated) > $1.knownSize(for: .allocated) }.prefix(3).map { $0 }
        let lines = CleanupQueueTree.lines(.init(
            entries: [], nodes: nodes, current: nodes[1],
            directoryChildren: children[1]!, directoryCount: 1,
            peekChildren: [10: largest3], peekCounts: [10: 5]))
        // Expanded: the three largest children by size, then paging for the rest.
        #expect(lines.map(\.id) == ["header-1", "item-10", "item-11", "item-12", "item-13", "showMore-10"])
        guard case .item(let first) = lines[2] else { Issue.record("Expected peeked children"); return }
        #expect(first.node.id == 11 && first.depth == 1 && first.bytes == 500)
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
        // The partial root shows selected over the root's own known total.
        #expect(rootRow.bytes == 40 && rootRow.totalBytes == 100)
        #expect(folderRow.bytes == 40 && folderRow.totalBytes == nil && !folderRow.hasHiddenChildren && !folderRow.hasSelectedDescendants)
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

    @Test func groupRootListingNeverDuplicatesContainersAtTheBottom() {
        // Grouped scans open at the synthetic wrapper, whose listing shows the listed
        // locations. A nested selection must not re-render its container at the bottom:
        // real paths are never lexically "within" the synthetic wrapper path.
        let wrapper = node(100, nil, ScanGroup.path, dir: true)
        let location = node(1, 100, "/Users/gw/Library/Developer/Xcode/DerivedData", dir: true, size: 100)
        let build = node(2, 1, "/Users/gw/Library/Developer/Xcode/DerivedData/BuildA", dir: true, size: 60)
        let obj = node(3, 2, "/Users/gw/Library/Developer/Xcode/DerivedData/BuildA/o.o", dir: false, size: 60)
        let other = node(4, 2, "/Users/gw/Library/Developer/Xcode/DerivedData/BuildA/keep.o", dir: false, size: 0)
        let caches = node(5, 100, "/Users/gw/Library/Caches", dir: true, size: 40)
        let nodes: [Int64: FileNode] = [100: wrapper, 1: location, 2: build, 3: obj, 4: other, 5: caches]
        let entries = [CleanupEntry(node: obj, operation: .remove)]
        let lines = CleanupQueueTree.lines(.init(
            entries: entries, nodes: nodes, current: wrapper,
            directoryChildren: [location, caches], directoryCount: 2, childCounts: [1: 1, 2: 2]))
        #expect(lines.map(\.id) == ["header-100", "item-1", "item-2", "item-3", "more-2", "item-5"])
        // No identity is ever rendered twice.
        #expect(Set(lines.map(\.id)).count == lines.count)
    }

    @Test func coveredContainerExpandsToItsEntries() {
        let (nodes, _) = fixture()
        // Both children of folder are queued: one atomic kept-folder row by default.
        let entries = [CleanupEntry(node: nodes[6]!, operation: .remove), CleanupEntry(node: nodes[3]!, operation: .remove)]
        let collapsedLines = CleanupQueueTree.lines(.init(entries: entries, nodes: nodes, childCounts: [1: 3, 2: 2]))
        #expect(collapsedLines.map(\.id) == ["item-1", "item-2", "more-1"])
        guard case .item(let folderRow) = collapsedLines[1] else { Issue.record("Expected the covered container row"); return }
        #expect(folderRow.coversAllChildren && folderRow.checkState == .checked && folderRow.hasSelectedDescendants)
        // The covered container's selected children equal the folder's known total, so
        // the readout stays the single size (no redundant slash).
        #expect(folderRow.bytes == 40 && folderRow.totalBytes == 40)
        // Expanding reveals the individual entries beneath it.
        let openLines = CleanupQueueTree.lines(.init(
            entries: entries, nodes: nodes, childCounts: [1: 3, 2: 2], coveredExpanded: ["/Users/xqueue/t/folder"]))
        #expect(openLines.map(\.id) == ["item-1", "item-2", "item-6", "item-3", "more-1"])
    }

    @Test func rowSizeTextShowsSelectedOverTotalOnlyForPartialFolders() {
        // A partial folder reads "selected/total" through the slash...
        let selected = Int64(5_200_000_000)
        let total = Int64(50_000_000_000)
        let composed = queueRowSizeText(selected: selected, total: total)
        #expect(composed == sizeText(selected) + "/" + sizeText(total))
        #expect(composed.contains("/"))
        // ...identical selected and totals, unknown totals, and unknown selections
        // render the single size without a slash...
        #expect(queueRowSizeText(selected: 40, total: 40) == sizeText(40))
        #expect(queueRowSizeText(selected: 40, total: nil) == sizeText(40))
        #expect(queueRowSizeText(selected: nil, total: 40) == sizeText(nil))
        // ...and an unselected folder row (nothing selected inside) has no total at all.
        let (nodes, children) = fixture()
        let lines = CleanupQueueTree.lines(.init(
            entries: [], nodes: nodes, current: nodes[1],
            directoryChildren: children[1]!.sorted { $0.knownSize(for: .allocated) > $1.knownSize(for: .allocated) },
            directoryCount: 3))
        guard case .item(let folderRow) = lines[1] else { Issue.record("Expected the folder row"); return }
        #expect(folderRow.checkState == .unchecked && folderRow.totalBytes == nil)
    }

    @Test func selectionMirrorReachesCoveredEntriesAtTheGroupWrapper() async throws {
        let wrapper = node(100, nil, ScanGroup.path, dir: true)
        let location = node(1, 100, "/Users/gw/Library/Developer/Xcode/DerivedData", dir: true, size: 60)
        let build = node(2, 1, "/Users/gw/Library/Developer/Xcode/DerivedData/BuildA", dir: true, size: 60)
        let obj = node(3, 2, "/Users/gw/Library/Developer/Xcode/DerivedData/BuildA/o.o", dir: false, size: 60)
        let nodes: [Int64: FileNode] = [100: wrapper, 1: location, 2: build, 3: obj]
        let children: [Int64: [FileNode]] = [100: [location], 1: [build], 2: [obj]]
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: "/Users/gw")
        cleanup.basket = [CleanupEntry(node: obj, operation: .remove)]
        let model = CleanupQueueModel(cleanup: cleanup)
        model.attach(StubQueueProvider(nodes: nodes, childrenByID: children))
        await model.refresh(current: wrapper)
        // The nested entry hides under its covered container; nothing is duplicated.
        #expect(model.lines.map(\.id) == ["header-100", "item-1", "item-2"])
        // The map-selection mirror expands the covered chain so the entry row exists.
        await model.revealForSelection(obj)
        #expect(model.lines.map(\.id) == ["header-100", "item-1", "item-2", "item-3"])
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

    @Test func modelListsCurrentFolderAndGathersLazySiblings() async throws {
        let (nodes, children) = fixture()
        let service = RecordingCleanupService()
        let cleanup = CleanupViewModel(service: service, homePath: "/Users/xqueue")
        cleanup.basket = [CleanupEntry(node: nodes[6]!, operation: .remove)]
        let model = CleanupQueueModel(cleanup: cleanup)
        model.pageSize = 2
        model.attach(StubQueueProvider(nodes: nodes, childrenByID: children))
        await model.refresh(current: nodes[1])
        // The open folder is listed even though only one deep file is selected, and the
        // selected descendant nests under its folder's row — which keeps its hidden-
        // siblings expander. The page limit is respected.
        #expect(model.lines.map(\.id) == ["header-1", "item-2", "item-6", "more-2", "item-5", "showMore-1"])
        // Loading more appends the remaining children and drops the pagination row.
        await model.loadMore(of: nodes[1]!)
        #expect(model.lines.map(\.id) == ["header-1", "item-2", "item-6", "more-2", "item-5", "item-4"])
        // Revealing unselected siblings loads one page of children lazily.
        await model.toggleRevealed(nodes[2]!).value
        #expect(model.lines.map(\.id) == ["header-1", "item-2", "item-6", "item-3", "item-5", "item-4"])
        // Unchecking the entry keeps the listing and empties the selected tree.
        cleanup.basket = []
        await model.refresh(current: nodes[1])
        #expect(model.lines.map(\.id) == ["header-1", "item-2", "item-5", "item-4"])
    }

    @Test func modelPeeksLargestChildrenLazily() async throws {
        let (nodes, children) = boxFixture()
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: "/t2")
        let model = CleanupQueueModel(cleanup: cleanup)
        model.attach(StubQueueProvider(nodes: nodes, childrenByID: children))
        await model.refresh(current: nodes[1])
        #expect(model.lines.map(\.id) == ["header-1", "item-10"])
        // Expanding shows the three largest children; the rest stay behind Show more.
        await model.togglePeek(nodes[10]!).value
        #expect(model.lines.map(\.id) == ["header-1", "item-10", "item-11", "item-12", "item-13", "showMore-10"])
        // Show more pages the rest in.
        await model.loadMore(of: nodes[10]!)
        #expect(model.lines.map(\.id) == ["header-1", "item-10", "item-11", "item-12", "item-13", "item-14", "item-15"])
        // Toggling again collapses the peek.
        await model.togglePeek(nodes[10]!).value
        #expect(model.lines.map(\.id) == ["header-1", "item-10"])
    }

    @Test func revealForSelectionExpandsChainToReachDeepSelection() async throws {
        let (nodes, children) = boxFixture()
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: "/t2")
        let model = CleanupQueueModel(cleanup: cleanup)
        model.pageSize = 2
        model.attach(StubQueueProvider(nodes: nodes, childrenByID: children))
        await model.refresh(current: nodes[1])
        #expect(model.lines.map(\.id) == ["header-1", "item-10"])
        // The fifth-largest child sits beyond the first peek page; revealing a selection
        // pages the folder until the selected item is visible.
        await model.revealForSelection(nodes[15]!)
        #expect(model.isPeeked(nodes[10]!))
        #expect(model.lines.map(\.id) == ["header-1", "item-10", "item-11", "item-12", "item-13", "item-14", "item-15"])
        // Items outside the open folder expand nothing.
        let outside = node(99, nil, "/t3/other.bin", dir: false, size: 7)
        await model.revealForSelection(outside)
        #expect(model.lines.map(\.id) == ["header-1", "item-10", "item-11", "item-12", "item-13", "item-14", "item-15"])
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
