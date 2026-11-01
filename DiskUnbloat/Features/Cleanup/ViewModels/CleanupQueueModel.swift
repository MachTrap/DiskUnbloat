import Foundation
import Observation
import DiskCore

/// Presentation state for the cleanup-queue panel: the compact tree of selected items and
/// the local expansion state used to reveal hidden siblings. The queue itself stays in
/// `CleanupViewModel.basket`; this model only derives rows and lazily fetches tree context.
@MainActor @Observable final class CleanupQueueModel {
    let cleanup: CleanupViewModel
    @ObservationIgnored private var provider: (any CleanupQueueProviding)?
    @ObservationIgnored private var nodesByID: [Int64: FileNode] = [:]
    @ObservationIgnored private var fetchedChildren: [Int64: [FileNode]] = [:]
    @ObservationIgnored private var childCounts: [Int64: Int] = [:]
    @ObservationIgnored private var generation = 0
    /// Folder paths whose unselected direct children are revealed.
    var revealed: Set<String> = []
    /// Partially selected folder paths the user collapsed.
    var collapsed: Set<String> = []
    private(set) var lines: [CleanupQueueLine] = []
    private(set) var isLoading = false
    let pageSize = 100

    init(cleanup: CleanupViewModel) { self.cleanup = cleanup }

    var selectedCount: Int { cleanup.basket.count }
    var selectedBytes: Int64 { cleanup.estimatedBytes }

    func attach(_ provider: (any CleanupQueueProviding)?) {
        self.provider = provider
        resetCaches()
    }

    func reset() {
        provider = nil
        revealed = []
        collapsed = []
        resetCaches()
    }

    private func resetCaches() {
        generation += 1
        nodesByID = [:]
        fetchedChildren = [:]
        childCounts = [:]
        lines = []
    }

    /// Rebuild the tree for the current queue. Idempotent; callers re-run it when the
    /// queue revision or the expansion state changes. Fetched child pages survive
    /// rebuilds so revealed folders keep their pagination.
    func refresh() async {
        guard let provider, !cleanup.basket.isEmpty else {
            generation += 1
            nodesByID = [:]
            fetchedChildren = [:]
            childCounts = [:]
            lines = []
            return
        }
        let entries = cleanup.basket
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        var nodes: [Int64: FileNode] = [:]
        for entry in entries { nodes[entry.node.id] = entry.node }
        // Resolve each entry's strict ancestors so partial folders can be shown. The
        // synthetic group wrapper is never a row; real roots become top-level entries.
        for entry in entries {
            var child = entry.node
            while let parentID = child.parentID, nodes[parentID] == nil {
                guard let parent = await provider.node(id: parentID), gen == generation else { return }
                if parent.isGroupRoot { break }
                nodes[parentID] = parent
                child = parent
            }
        }
        // Partial folders need child counts (for honest hidden badges) and, where the
        // user revealed them, paged unselected children.
        for node in nodes.values where isPartialAncestor(node, entries: entries) {
            if childCounts[node.id] == nil {
                childCounts[node.id] = await provider.childCount(of: node.id)
                if gen != generation { return }
            }
            if revealed.contains(node.path), fetchedChildren[node.id] == nil {
                fetchedChildren[node.id] = await provider.children(of: node.id, limit: pageSize, offset: 0)
                if gen != generation { return }
            }
        }
        nodesByID = nodes
        lines = makeLines(entries: entries)
    }

    /// Load the next page of revealed children for one folder.
    func loadMore(of node: FileNode) async {
        guard let provider else { return }
        let gen = generation
        let offset = fetchedChildren[node.id]?.count ?? 0
        let page = await provider.children(of: node.id, limit: pageSize, offset: offset)
        guard gen == generation else { return }
        fetchedChildren[node.id, default: []] += page
        lines = makeLines(entries: cleanup.basket)
    }

    /// Reveal or hide one folder's unselected direct children.
    func toggleRevealed(_ node: FileNode) {
        if revealed.contains(node.path) { revealed.remove(node.path) }
        else { revealed.insert(node.path) }
        Task { await refresh() }
    }

    /// Expand or collapse one partially selected folder's selected children.
    func toggleCollapsed(_ node: FileNode) {
        if collapsed.contains(node.path) { collapsed.remove(node.path) }
        else { collapsed.insert(node.path) }
        lines = makeLines(entries: cleanup.basket)
    }

    private func makeLines(entries: [CleanupEntry]) -> [CleanupQueueLine] {
        CleanupQueueTree.lines(CleanupQueueTree.Input(
            entries: entries, nodes: nodesByID, childCounts: childCounts,
            fetchedChildren: fetchedChildren, revealed: revealed, collapsed: collapsed))
    }

    private func isPartialAncestor(_ node: FileNode, entries: [CleanupEntry]) -> Bool {
        guard !node.isGroupRoot else { return false }
        return !entries.contains { $0.node.id == node.id } && entries.contains { $0.node.path.isWithin(node.path) }
    }
}
