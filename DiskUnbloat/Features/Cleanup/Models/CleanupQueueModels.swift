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
    /// descendants total, or a revealed unselected child's own known size for context.
    let bytes: Int64
    let hasSelectedDescendants: Bool
    let hasHiddenChildren: Bool
    let hiddenChildCount: Int
    var id: Int64 { node.id }
    var isEntry: Bool { checkState == .checked }
    var keepsFolder: Bool { operation == .emptyContents }
}

/// One line of the queue list: an item row, a "hidden items" expander, or a pagination row.
enum CleanupQueueLine: Identifiable, Sendable, Equatable {
    case item(CleanupQueueRow)
    /// `… N more items`: reveals unselected direct children hidden by default.
    case more(FileNode, depth: Int, hiddenChildCount: Int)
    /// `Show more items`: loads the next page of already-revealed children.
    case showMore(FileNode, depth: Int)

    var id: String {
        switch self {
        case .item(let row): "item-\(row.id)"
        case .more(let node, _, _): "more-\(node.id)"
        case .showMore(let node, _): "showMore-\(node.id)"
        }
    }
}

/// Pure queue-tree projection. Builds the compact hierarchy the panel renders:
/// normalized entries, their partial ancestors (auto-expanded, selected children first),
/// and unselected direct children only where the user revealed them.
enum CleanupQueueTree {
    struct Input {
        /// Normalized cleanup entries; topmost kept entries, disjoint subtrees.
        var entries: [CleanupEntry]
        /// Every node the gather resolved: entries plus their strict ancestors.
        var nodes: [Int64: FileNode]
        /// Exact direct-child counts per folder, for honest hidden-item badges.
        var childCounts: [Int64: Int] = [:]
        /// Fetched direct-child pages per folder, for revealed unselected children.
        var fetchedChildren: [Int64: [FileNode]] = [:]
        var revealed: Set<String> = []
        var collapsed: Set<String> = []
    }

    static func lines(_ input: Input) -> [CleanupQueueLine] {
        let entryByID = Dictionary(uniqueKeysWithValues: input.entries.map { ($0.node.id, $0) })
        // Structural children: exact entries and strict ancestors of entries, per parent.
        var structural: [Int64: Set<Int64>] = [:]
        var ancestors: Set<Int64> = []
        for entry in input.entries {
            var child = entry.node
            while let parentID = child.parentID, let parent = input.nodes[parentID], !parent.isGroupRoot {
                structural[parentID, default: []].insert(child.id)
                ancestors.insert(parentID)
                child = parent
            }
        }
        // Top-level rows: everything whose parent is absent or the synthetic group wrapper.
        let referenced = Set(entryByID.keys).union(ancestors)
        let roots = referenced.compactMap { input.nodes[$0] }.filter { node in
            guard let parentID = node.parentID, let parent = input.nodes[parentID] else { return true }
            return parent.isGroupRoot
        }.sorted { $0.path < $1.path }

        var out: [CleanupQueueLine] = []
        for root in roots { render(root, depth: 0, input: input, entryByID: entryByID, structural: structural, into: &out) }
        return out
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
                hasSelectedDescendants: false, hasHiddenChildren: false, hiddenChildCount: 0)))
            return
        }
        let kids = structural[node.id] ?? []
        let total = input.childCounts[node.id] ?? kids.count
        let hiddenCount = max(0, total - kids.count)
        let selectedBytes = input.entries.reduce(Int64(0)) { sum, entry in
            entry.node.path.isWithin(node.path) ? sum + entry.node.knownSize(for: .allocated) : sum
        }
        out.append(.item(CleanupQueueRow(
            node: node, depth: depth, checkState: .partial, operation: nil,
            bytes: selectedBytes,
            hasSelectedDescendants: true, hasHiddenChildren: hiddenCount > 0, hiddenChildCount: hiddenCount)))
        guard !input.collapsed.contains(node.path) else { return }
        // Selected children first, then partially selected descendants, both in path order.
        let childNodes = kids.compactMap { input.nodes[$0] }
        let selectedKids = childNodes.filter { entryByID[$0.id] != nil }.sorted { $0.path < $1.path }
        let partialKids = childNodes.filter { entryByID[$0.id] == nil }.sorted { $0.path < $1.path }
        for child in selectedKids {
            render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, into: &out)
        }
        for child in partialKids {
            render(child, depth: depth + 1, input: input, entryByID: entryByID, structural: structural, into: &out)
        }
        if input.revealed.contains(node.path), let fetched = input.fetchedChildren[node.id] {
            for child in fetched where !kids.contains(child.id) {
                out.append(.item(CleanupQueueRow(
                    node: child, depth: depth + 1, checkState: .unchecked, operation: nil,
                    bytes: child.knownSize(for: .allocated),
                    hasSelectedDescendants: false, hasHiddenChildren: false, hiddenChildCount: 0)))
            }
            if fetched.count < total { out.append(.showMore(node, depth: depth + 1)) }
        } else if hiddenCount > 0 {
            out.append(.more(node, depth: depth + 1, hiddenChildCount: hiddenCount))
        }
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
    func children(of parentID: Int64, limit: Int, offset: Int) async -> [FileNode]
    func childCount(of parentID: Int64) async -> Int
}

/// `CleanupQueueProviding` backed by the session's `ScanIndex`.
struct IndexCleanupQueueProvider: CleanupQueueProviding {
    let index: ScanIndex
    let inspectPackages: Bool
    func node(id: Int64) async -> FileNode? { await index.node(id) }
    func children(of parentID: Int64, limit: Int, offset: Int) async -> [FileNode] {
        await index.children(of: parentID, inspectPackages: inspectPackages, limit: limit, offset: offset)
    }
    func childCount(of parentID: Int64) async -> Int {
        await index.childCount(of: parentID, inspectPackages: inspectPackages)
    }
}
