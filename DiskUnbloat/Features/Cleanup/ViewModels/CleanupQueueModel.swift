import Foundation
import Observation
import DiskCore

/// Presentation state for the cleanup-queue panel: the current open folder's listing
/// (size-descending, selectable), the selected-items tree outside it, and the local
/// expansion state used to reveal hidden siblings. The queue itself stays in
/// `CleanupViewModel.basket`; this model only derives rows and lazily fetches tree context.
@MainActor @Observable final class CleanupQueueModel {
    let cleanup: CleanupViewModel
    @ObservationIgnored private var provider: (any CleanupQueueProviding)?
    @ObservationIgnored private var nodesByID: [Int64: FileNode] = [:]
    @ObservationIgnored private var fetchedChildren: [Int64: [FileNode]] = [:]
    @ObservationIgnored private var childCounts: [Int64: Int] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var current: FileNode?
    @ObservationIgnored private var directoryParentID: Int64?
    @ObservationIgnored private var directoryChildren: [FileNode] = []
    /// Unselected plain folders the user expanded to peek inside.
    @ObservationIgnored private var peeks: [Int64: FileNode] = [:]
    @ObservationIgnored private var peekChildren: [Int64: [FileNode]] = [:]
    @ObservationIgnored private var peekCounts: [Int64: Int] = [:]
    /// Folder paths whose unselected direct children are revealed.
    var revealed: Set<String> = []
    /// Partially selected folder paths the user collapsed.
    var collapsed: Set<String> = []
    private(set) var lines: [CleanupQueueLine] = []
    private(set) var isLoading = false
    var pageSize = 100
    /// Largest children shown when a folder is first expanded.
    let peekLimit = 3

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

    /// Drop fetched tree context after a branch refresh changed the underlying rows.
    func invalidateCaches() {
        resetCaches()
        Task { await refresh(current: current) }
    }

    private func resetCaches() {
        generation += 1
        nodesByID = [:]
        fetchedChildren = [:]
        childCounts = [:]
        directoryParentID = nil
        directoryChildren = []
        peeks = [:]
        peekChildren = [:]
        peekCounts = [:]
        lines = []
    }

    /// Rebuild the panel for the current queue and open folder. The current-folder
    /// listing appears even when the queue is empty. Idempotent; callers re-run it when
    /// the queue revision or the expansion state changes.
    func refresh(current: FileNode? = nil) async {
        if let current { self.current = current }
        guard let provider else {
            generation += 1
            lines = []
            return
        }
        let entries = cleanup.basket
        let openFolder = self.current
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        // The open folder's direct children, by known size descending. Fetched pages
        // survive rebuilds so pagination keeps its position.
        if let openFolder, openFolder.id != directoryParentID {
            directoryChildren = await provider.children(of: openFolder.id, limit: pageSize, offset: 0, sortByName: false)
            if gen != generation { return }
            directoryParentID = openFolder.id
        }
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
                fetchedChildren[node.id] = await provider.children(of: node.id, limit: pageSize, offset: 0, sortByName: true)
                if gen != generation { return }
            }
        }
        // Peeked folders keep their largest-first child pages across rebuilds.
        for node in peeks.values where peekChildren[node.id] == nil {
            peekChildren[node.id] = await provider.children(of: node.id, limit: peekLimit, offset: 0, sortByName: false)
            if gen != generation { return }
            peekCounts[node.id] = await provider.childCount(of: node.id)
            if gen != generation { return }
        }
        nodesByID = nodes
        var input = CleanupQueueTree.Input(
            entries: entries, nodes: nodes, current: openFolder,
            directoryChildren: openFolder?.id == directoryParentID ? directoryChildren : [],
            childCounts: childCounts,
            fetchedChildren: fetchedChildren, peekChildren: peekChildren, peekCounts: peekCounts,
            revealed: revealed, collapsed: collapsed)
        if let openFolder, directoryParentID == openFolder.id {
            input.directoryCount = await provider.childCount(of: openFolder.id)
            if gen != generation { return }
        }
        lines = CleanupQueueTree.lines(input)
    }

    /// Load the next page: of revealed unselected children, of a peeked folder's
    /// children, or of the open-folder listing.
    func loadMore(of node: FileNode) async {
        guard let provider else { return }
        let gen = generation
        if node.id == directoryParentID {
            let offset = directoryChildren.count
            let page = await provider.children(of: node.id, limit: pageSize, offset: offset, sortByName: false)
            guard gen == generation else { return }
            directoryChildren += page
        } else if peeks[node.id] != nil {
            let offset = peekChildren[node.id]?.count ?? 0
            let page = await provider.children(of: node.id, limit: pageSize, offset: offset, sortByName: false)
            guard gen == generation else { return }
            peekChildren[node.id, default: []] += page
        } else {
            let offset = fetchedChildren[node.id]?.count ?? 0
            let page = await provider.children(of: node.id, limit: pageSize, offset: offset, sortByName: true)
            guard gen == generation else { return }
            fetchedChildren[node.id, default: []] += page
        }
        lines = makeLines()
    }

    /// Whether a folder's lazy peek is currently expanded.
    func isPeeked(_ node: FileNode) -> Bool { peeks[node.id] != nil }

    /// Expand or collapse an unselected folder's largest-children peek.
    func togglePeek(_ node: FileNode) {
        if peeks[node.id] != nil {
            peeks[node.id] = nil
            peekChildren[node.id] = nil
            peekCounts[node.id] = nil
        } else {
            peeks[node.id] = node
        }
        Task { await refresh() }
    }

    /// Expand the folder chain between the open folder and a selected item so its row
    /// exists in the panel; pages folders whose target child lies beyond the first page.
    func revealForSelection(_ node: FileNode) async {
        guard let provider, let current else { return }
        guard node.path != current.path, node.path.isWithin(current.path) else { return }
        var targets: [(folder: FileNode, child: FileNode)] = []
        var cursor = node
        while let parentID = cursor.parentID, let parent = await provider.node(id: parentID) {
            if parent.path == current.path || parent.isGroupRoot { break }
            // Packages and symlinks stay atomic; the chain ends there.
            guard parent.isDirectory, !parent.isSymbolicLink, !parent.isPackage else { break }
            targets.append((parent, cursor))
            cursor = parent
        }
        guard !targets.isEmpty else { return }
        let gen = generation
        for (folder, child) in targets.reversed() {
            if peeks[folder.id] == nil { peeks[folder.id] = folder }
            if peekChildren[folder.id] == nil {
                let page = await provider.children(of: folder.id, limit: peekLimit, offset: 0, sortByName: false)
                guard gen == generation else { return }
                peekChildren[folder.id] = page
                peekCounts[folder.id] = await provider.childCount(of: folder.id)
                guard gen == generation else { return }
            }
            var fetched = peekChildren[folder.id] ?? []
            while !fetched.contains(where: { $0.id == child.id }), fetched.count < (peekCounts[folder.id] ?? 0) {
                let page = await provider.children(of: folder.id, limit: pageSize, offset: fetched.count, sortByName: false)
                guard gen == generation, !page.isEmpty else { return }
                fetched += page
                peekChildren[folder.id] = fetched
            }
        }
        lines = makeLines()
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
        lines = makeLines()
    }

    private func makeLines() -> [CleanupQueueLine] {
        let openFolder = current
        return CleanupQueueTree.lines(CleanupQueueTree.Input(
            entries: cleanup.basket, nodes: nodesByID, current: openFolder,
            directoryChildren: openFolder?.id == directoryParentID ? directoryChildren : [],
            childCounts: childCounts,
            fetchedChildren: fetchedChildren, peekChildren: peekChildren, peekCounts: peekCounts,
            revealed: revealed, collapsed: collapsed))
    }

    private func isPartialAncestor(_ node: FileNode, entries: [CleanupEntry]) -> Bool {
        guard !node.isGroupRoot else { return false }
        return !entries.contains { $0.node.id == node.id } && entries.contains { $0.node.path.isWithin(node.path) }
    }
}
