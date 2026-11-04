import Foundation
import DiskCore

/// Checkbox state of one cleanup-queue row.
enum CleanupQueueCheckState: Sendable, Equatable {
    case unchecked
    case partial
    case checked
}

/// One rendered row of the cleanup-queue tree: a node plus what selecting it means.
struct CleanupQueueRow: Identifiable, Sendable, Equatable {
    let node: FileNode
    let depth: Int
    let checkState: CleanupQueueCheckState
    /// Present only for exact queue entries.
    let operation: CleanupOperation?
    /// Size attributed to this row: an entry's known size, a partial folder's selected
    /// descendants total, or an unselected child's own known size for context.
    let bytes: Int64
    /// The directory's own known size, shown after the selected part through a slash
    /// ("5.2/50 GB") when selection covers only part of this row's subtree. `nil` for
    /// rows where nothing is selected inside or the total is unknown.
    let totalBytes: Int64?
    let hasSelectedDescendants: Bool
    /// Unselected plain folders can be expanded to peek at their largest children.
    let canPeek: Bool
    let hasHiddenChildren: Bool
    let hiddenChildCount: Int
    /// Every indexed child of this container is queued: one atomic row whose contents go
    /// while the folder itself stays. Collapsed by default; expanding lists its entries.
    var coversAllChildren = false
    var id: Int64 { node.id }
    var isEntry: Bool { checkState == .checked }
    var keepsFolder: Bool { operation == .emptyContents || coversAllChildren }
}

/// One line of the queue list: the current-folder header, an item row, a "hidden items"
/// expander, or a pagination row.
enum CleanupQueueLine: Identifiable, Sendable, Equatable {
    /// Section header naming the currently open folder the listing below belongs to.
    case directoryHeader(FileNode)
    case item(CleanupQueueRow)
    /// `… N more items`: reveals unselected direct children hidden by default.
    case more(FileNode, depth: Int, hiddenChildCount: Int)
    /// `Show more items`: loads the next page of already-revealed children or the
    /// current-folder listing.
    case showMore(FileNode, depth: Int)

    var id: String {
        switch self {
        case .directoryHeader(let node): "header-\(node.id)"
        case .item(let row): "item-\(row.id)"
        case .more(let node, _, _): "more-\(node.id)"
        case .showMore(let node, _): "showMore-\(node.id)"
        }
    }
}

/// Pure queue projection. Builds two sections:
/// - the current open folder's direct children, sorted by known size descending, with
///   selected entries checked and partially selected folders expanded — so the panel is
///   a browsable listing even before anything is selected;
/// - the selected-items tree for entries outside that folder.
enum CleanupQueueTree {
    struct Input {
        /// Normalized cleanup entries; topmost kept entries, disjoint subtrees.
        var entries: [CleanupEntry]
        /// Every node the gather resolved: entries plus their strict ancestors.
        var nodes: [Int64: FileNode]
        /// The currently open folder; the listing section is built around it.
        var current: FileNode?
        /// Direct children of `current` in display order (known size descending).
        var directoryChildren: [FileNode] = []
        /// Total direct-child count of `current`, for honest pagination.
        var directoryCount: Int? = nil
        /// Exact direct-child counts per folder, for honest hidden-item badges.
        var childCounts: [Int64: Int] = [:]
        /// Fetched direct-child pages per folder, for revealed unselected children.
        var fetchedChildren: [Int64: [FileNode]] = [:]
        /// Largest-first child pages per peeked unselected folder.
        var peekChildren: [Int64: [FileNode]] = [:]
        /// Exact direct-child counts of peeked folders, for honest "show more" rows.
        var peekCounts: [Int64: Int] = [:]
        var revealed: Set<String> = []
        var collapsed: Set<String> = []
        /// Covered containers the user expanded to review their individual entries.
        var coveredExpanded: Set<String> = []
    }

    static func lines(_ input: Input) -> [CleanupQueueLine] {
        let entryByID = Dictionary(uniqueKeysWithValues: input.entries.map { ($0.node.id, $0) })
        let structural = structuralChildren(entries: input.entries, nodes: input.nodes, current: input.current)
        let selectedBytes = selectedBytesByNode(input)
        var out: [CleanupQueueLine] = []
        // The current open folder: a listing of its direct children by known size, so the
        // panel shows content even with an empty queue. Selected descendants of a partial
        // child nest directly beneath its row.
        if let current = input.current {
            out.append(.directoryHeader(current))
            let shown = input.directoryChildren
            for child in shown {
                render(child, depth: 0, input: input, entryByID: entryByID, structural: structural, selectedBytes: selectedBytes, into: &out)
            }
            let total = input.directoryCount ?? shown.count
            if shown.count < total { out.append(.showMore(current, depth: 0)) }
        }
        // Entries elsewhere in the scan keep their full ancestor tree above the listing.
        // Everything the listing already shows belongs to the open folder's subtree —
        // for the synthetic group wrapper that is the whole scan, since real paths are
        // never lexically "within" the synthetic path.
        let parents = Set(structural.keys)
        let roots = Set(entryByID.keys).union(parents)
            .compactMap { input.nodes[$0] }
            .filter { node in
                if let current = input.current, current.isGroupRoot || node.path.isWithin(current.path) { return false }
                guard let parentID = node.parentID, let parent = input.nodes[parentID] else { return true }
                return parent.isGroupRoot
            }
            .sorted(by: bySize)
        for root in roots { render(root, depth: 0, input: input, entryByID: entryByID, structural: structural, selectedBytes: selectedBytes, into: &out) }
        return out
    }

    /// Selected bytes per node id: every entry's known size is attributed to itself and
    /// each ancestor the gather resolved, in one pass instead of a per-row scan over all
    /// entries.
    private static func selectedBytesByNode(_ input: Input) -> [Int64: Int64] {
        var totals: [Int64: Int64] = [:]
        for entry in input.entries {
            let bytes = entry.node.knownSize(for: .allocated)
            var node: FileNode? = entry.node
            while let current = node {
                totals[current.id, default: 0] += bytes
                node = current.parentID.flatMap { input.nodes[$0] }
            }
        }
        return totals
    }

    /// Known-size descending, path as the deterministic tie-break.
    private static func bySize(_ a: FileNode, _ b: FileNode) -> Bool {
        let left = a.knownSize(for: .allocated)
        let right = b.knownSize(for: .allocated)
        return left == right ? a.path < b.path : left > right
    }

    /// Parent → structural children: exact entries and strict ancestors of entries. The
    /// chain stops at the current folder, so its children become the inner roots.
    private static func structuralChildren(
        entries: [CleanupEntry], nodes: [Int64: FileNode], current: FileNode?
    ) -> [Int64: Set<Int64>] {
        var structural: [Int64: Set<Int64>] = [:]
        for entry in entries {
            var child = entry.node
            while let parentID = child.parentID, let parent = nodes[parentID], !parent.isGroupRoot {
                if let current, parent.path == current.path { break }
                structural[parentID, default: []].insert(child.id)
                child = parent
            }
        }
        return structural
    }

    private static func render(
        _ node: FileNode,
        depth: Int,
        input: Input,
        entryByID: [Int64: CleanupEntry],
        structural: [Int64: Set<Int64>],
        selectedBytes: [Int64: Int64],
        into out: inout [CleanupQueueLine]
    ) {
        if let entry = entryByID[node.id] {
            // An exact entry is atomic: its whole subtree disappears with it, so the row
            // stays compact with no expansion controls.
            out.append(.item(CleanupQueueRow(
                node: node, depth: depth, checkState: .checked, operation: entry.operation,
                bytes: node.knownSize(for: .allocated), totalBytes: nil,
                hasSelectedDescendants: false, canPeek: false, hasHiddenChildren: false, hiddenChildCount: 0)))
            return
        }
        let kids = (structural[node.id] ?? []).compactMap { input.nodes[$0] }.sorted(by: bySize)
        // A container whose every indexed child is queued reads as one atomic checked row:
        // its contents disappear while the folder itself stays, exactly as an emptied
        // scan root does. It is collapsed by default so a bulk selection stays one row;
        // expanding reveals the individual entries and keeps the map-selection mirror
        // able to reach them.
        if !kids.isEmpty, let count = input.childCounts[node.id], kids.count == count,
           kids.allSatisfy({ entryByID[$0.id] != nil }) {
            out.append(.item(CleanupQueueRow(
                node: node, depth: depth, checkState: .checked, operation: nil,
                bytes: selectedBytes[node.id] ?? 0, totalBytes: node.knownSize(for: .allocated),
                hasSelectedDescendants: true, canPeek: false, hasHiddenChildren: false, hiddenChildCount: 0,
                coversAllChildren: true)))
            if input.coveredExpanded.contains(node.path) {
                for child in kids {
                    render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, selectedBytes: selectedBytes, into: &out)
                }
            }
            return
        }
        let total = input.childCounts[node.id] ?? kids.count
        let hiddenCount = max(0, total - kids.count)
        out.append(.item(CleanupQueueRow(
            node: node, depth: depth,
            checkState: kids.isEmpty ? .unchecked : .partial, operation: nil,
            bytes: kids.isEmpty ? node.knownSize(for: .allocated) : (selectedBytes[node.id] ?? 0),
            totalBytes: kids.isEmpty ? nil : node.knownSize(for: .allocated),
            hasSelectedDescendants: !kids.isEmpty,
            canPeek: kids.isEmpty && isExpandableContainer(node),
            hasHiddenChildren: hiddenCount > 0, hiddenChildCount: hiddenCount)))
        if kids.isEmpty {
            // An unselected plain folder expands to a lazy peek at its largest children.
            if isExpandableContainer(node), let peeked = input.peekChildren[node.id] {
                for child in peeked {
                    render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, selectedBytes: selectedBytes, into: &out)
                }
                if peeked.count < (input.peekCounts[node.id] ?? peeked.count) {
                    out.append(.showMore(node, depth: depth + 1))
                }
            }
            return
        }
        guard !input.collapsed.contains(node.path) else { return }
        // Every structural child here is selected or partially selected; show them by size.
        for child in kids {
            render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, selectedBytes: selectedBytes, into: &out)
        }
        if input.revealed.contains(node.path), let fetched = input.fetchedChildren[node.id] {
            for child in fetched where !kids.contains(where: { $0.id == child.id }) {
                render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, selectedBytes: selectedBytes, into: &out)
            }
            if fetched.count < total { out.append(.showMore(node, depth: depth + 1)) }
        } else if hiddenCount > 0 {
            out.append(.more(node, depth: depth + 1, hiddenChildCount: hiddenCount))
        }
    }

    /// Plain folders can be expanded; packages and summarized folders stay atomic.
    private static func isExpandableContainer(_ node: FileNode) -> Bool {
        node.isBrowsable(inspectPackages: false)
    }
}

/// How a path relates to the cleanup queue, for context-menu wording.
enum QueueMembership: Sendable, Equatable {
    case none
    /// The path is an exact queue entry.
    case selected
    /// Queue entries exist strictly below the path; selecting the folder subsumes them.
    case containsSelection
    /// The path is covered by a queued ancestor entry.
    case insideSelection
}

/// O(depth) membership over the normalized queue instead of one linear scan per render:
/// every rendered row and every map tile asks once per frame, and a linear scan over a
/// bulk selection measured whole seconds of repaint jank. The queue is normalized
/// (topmost kept, disjoint subtrees), so a path's own parent chain answers every
/// relation — no per-path scan over the queue.
struct QueueMembershipIndex: Sendable {
    private let exact: Set<String>
    /// Folder paths with at least one queue entry strictly below them, collected in one
    /// pass over each entry's ancestor chain.
    private let foldersWithEntriesBelow: Set<String>

    init(entries: [CleanupEntry]) {
        exact = Set(entries.map { $0.node.path })
        var below = Set<String>()
        for entry in entries {
            var parent = URL(fileURLWithPath: entry.node.path).deletingLastPathComponent().path
            while parent.count > 1 {
                below.insert(parent)
                parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            }
        }
        foldersWithEntriesBelow = below
    }

    /// The path's own character: exact entry, covered by an ancestor entry first (the
    /// item goes with that selection even when other entries also lie below it), then a
    /// folder containing entries.
    func membership(of path: String) -> QueueMembership {
        if exact.contains(path) { return .selected }
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var containsEntry = false
        while parent.count > 1 {
            if exact.contains(parent) { return .insideSelection }
            if !containsEntry, foldersWithEntriesBelow.contains(parent) { containsEntry = true }
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
        return containsEntry ? .containsSelection : .none
    }
}

func queueMembership(path: String, queuedPaths: [String]) -> QueueMembership {
    if queuedPaths.contains(path) { return .selected }
    if queuedPaths.contains(where: { $0.isWithin(path) }) { return .containsSelection }
    if queuedPaths.contains(where: { path.isWithin($0) }) { return .insideSelection }
    return .none
}

/// Bounded reads the queue tree needs from the live scan index. Injectable so the
/// projection and gather can be tested without a database.
protocol CleanupQueueProviding: Sendable {
    func node(id: Int64) async -> FileNode?
    func children(of parentID: Int64, limit: Int, offset: Int, sortByName: Bool) async -> [FileNode]
    func childCount(of parentID: Int64) async -> Int
    /// Every ancestor row for the given start ids in one indexed round trip. A bulk
    /// selection gathers hundreds of chains; hop-by-hop looks on the scale of seconds.
    func ancestors(of ids: [Int64]) async -> [Int64: FileNode]
    /// Exact direct-child counts for many folders at once (hidden-item badges).
    func childCounts(of ids: [Int64]) async -> [Int64: Int]
}

/// `CleanupQueueProviding` backed by the session's `ScanIndex`.
struct IndexCleanupQueueProvider: CleanupQueueProviding {
    let index: ScanIndex
    let inspectPackages: Bool
    func node(id: Int64) async -> FileNode? { await index.node(id) }
    func children(of parentID: Int64, limit: Int, offset: Int, sortByName: Bool) async -> [FileNode] {
        await index.children(of: parentID, inspectPackages: inspectPackages, limit: limit, offset: offset, sortByName: sortByName)
    }
    func childCount(of parentID: Int64) async -> Int {
        await index.childCount(of: parentID, inspectPackages: inspectPackages)
    }
    func ancestors(of ids: [Int64]) async -> [Int64: FileNode] {
        await index.nodesWithAncestors(ids: ids)
    }
    func childCounts(of ids: [Int64]) async -> [Int64: Int] {
        await index.childCounts(of: ids, inspectPackages: inspectPackages)
    }
}
