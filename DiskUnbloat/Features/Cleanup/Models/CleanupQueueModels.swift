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
    let hasSelectedDescendants: Bool
    /// Unselected plain folders can be expanded to peek at their largest children.
    let canPeek: Bool
    let hasHiddenChildren: Bool
    let hiddenChildCount: Int
    var id: Int64 { node.id }
    var isEntry: Bool { checkState == .checked }
    var keepsFolder: Bool { operation == .emptyContents }
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
    }

    static func lines(_ input: Input) -> [CleanupQueueLine] {
        let entryByID = Dictionary(uniqueKeysWithValues: input.entries.map { ($0.node.id, $0) })
        let structural = structuralChildren(entries: input.entries, nodes: input.nodes, current: input.current)
        var out: [CleanupQueueLine] = []
        // The current open folder: a listing of its direct children by known size, so the
        // panel shows content even with an empty queue. Selected descendants of a partial
        // child nest directly beneath its row.
        if let current = input.current {
            out.append(.directoryHeader(current))
            let shown = input.directoryChildren
            for child in shown {
                render(child, depth: 0, input: input, entryByID: entryByID, structural: structural, into: &out)
            }
            let total = input.directoryCount ?? shown.count
            if shown.count < total { out.append(.showMore(current, depth: 0)) }
        }
        // Entries elsewhere in the scan keep their full ancestor tree above the listing.
        let parents = Set(structural.keys)
        let roots = Set(entryByID.keys).union(parents)
            .compactMap { input.nodes[$0] }
            .filter { node in
                if let current = input.current, node.path.isWithin(current.path) { return false }
                guard let parentID = node.parentID, let parent = input.nodes[parentID] else { return true }
                return parent.isGroupRoot
            }
            .sorted(by: bySize)
        for root in roots { render(root, depth: 0, input: input, entryByID: entryByID, structural: structural, into: &out) }
        return out
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
        into out: inout [CleanupQueueLine]
    ) {
        if let entry = entryByID[node.id] {
            // An exact entry is atomic: its whole subtree disappears with it, so the row
            // stays compact with no expansion controls.
            out.append(.item(CleanupQueueRow(
                node: node, depth: depth, checkState: .checked, operation: entry.operation,
                bytes: node.knownSize(for: .allocated),
                hasSelectedDescendants: false, canPeek: false, hasHiddenChildren: false, hiddenChildCount: 0)))
            return
        }
        let kids = (structural[node.id] ?? []).compactMap { input.nodes[$0] }.sorted(by: bySize)
        let total = input.childCounts[node.id] ?? kids.count
        let hiddenCount = max(0, total - kids.count)
        let selectedBytes = input.entries.reduce(Int64(0)) { sum, entry in
            entry.node.path.isWithin(node.path) ? sum + entry.node.knownSize(for: .allocated) : sum
        }
        out.append(.item(CleanupQueueRow(
            node: node, depth: depth,
            checkState: kids.isEmpty ? .unchecked : .partial, operation: nil,
            bytes: kids.isEmpty ? node.knownSize(for: .allocated) : selectedBytes,
            hasSelectedDescendants: !kids.isEmpty,
            canPeek: kids.isEmpty && isExpandableContainer(node),
            hasHiddenChildren: hiddenCount > 0, hiddenChildCount: hiddenCount)))
        if kids.isEmpty {
            // An unselected plain folder expands to a lazy peek at its largest children.
            if let peeked = input.peekChildren[node.id] {
                for child in peeked {
                    render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, into: &out)
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
            render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, into: &out)
        }
        if input.revealed.contains(node.path), let fetched = input.fetchedChildren[node.id] {
            for child in fetched where !kids.contains(where: { $0.id == child.id }) {
                render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, into: &out)
            }
            if fetched.count < total { out.append(.showMore(node, depth: depth + 1)) }
        } else if hiddenCount > 0 {
            out.append(.more(node, depth: depth + 1, hiddenChildCount: hiddenCount))
        }
    }

    /// Plain folders can be expanded; packages stay atomic unless inspection is on.
    private static func isExpandableContainer(_ node: FileNode) -> Bool {
        node.isDirectory && !node.isSymbolicLink && !node.isPackage
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
}
