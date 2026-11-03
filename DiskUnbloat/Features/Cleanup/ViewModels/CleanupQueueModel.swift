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
    /// Covered containers (all children queued) the user expanded to review entries.
    var coveredExpanded: Set<String> = []
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
        coveredExpanded = []
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
        // Resolve every entry's strict ancestors in a constant number of indexed batch
        // statements: a bulk selection gathers hundreds of chains, and hop-by-hop
        // provider round trips measured in minutes on the main actor.
        if !nodes.isEmpty {
            let gathered = await provider.ancestors(of: Array(nodes.keys))
            if gen != generation { return }
            nodes.merge(gathered) { a, _ in a }
        }
        // Partial folders (contain a queued entry without being queued themselves) need
        // child counts for honest hidden badges and, where revealed, paged unselected
        // children. Their ids fall out of the gather walk directly, so no per-node
        // scan over every entry is needed; an already-recorded ancestor means the rest
        // of that chain was processed earlier, so the walk can stop there.
        var entryIDs = Set(entries.map { $0.node.id })
        var partialAncestorIDs = Set<Int64>()
        for entry in entries {
            var child = entry.node
            while let parentID = child.parentID, let parent = nodes[parentID] {
                if parent.isGroupRoot || entryIDs.contains(parentID) { break }
                if partialAncestorIDs.insert(parentID).inserted == false { break }
                child = parent
            }
        }
        let partials = nodes.values.filter { partialAncestorIDs.contains($0.id) }
        let missingCounts = partials.filter { childCounts[$0.id] == nil }
        if !missingCounts.isEmpty {
            childCounts.merge(await provider.childCounts(of: missingCounts.map { $0.id })) { a, _ in a }
            if gen != generation { return }
        }
        for node in partials where revealed.contains(node.path) && fetchedChildren[node.id] == nil {
            fetchedChildren[node.id] = await provider.children(of: node.id, limit: pageSize, offset: 0, sortByName: true)
            if gen != generation { return }
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
            revealed: revealed, collapsed: collapsed, coveredExpanded: coveredExpanded)
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

    /// Expand or collapse an unselected folder's largest-children peek. Returns the
    /// refresh task so callers can await the rebuilt rows deterministically.
    @discardableResult
    func togglePeek(_ node: FileNode) -> Task<Void, Never> {
        if peeks[node.id] != nil {
            peeks[node.id] = nil
            peekChildren[node.id] = nil
            peekCounts[node.id] = nil
        } else {
            peeks[node.id] = node
        }
        return Task { await refresh() }
    }

    /// Expand the folder chain between the open folder and a selected item so its row
    /// exists in the panel; pages folders whose target child lies beyond the first page.
    func revealForSelection(_ node: FileNode) async {
        guard let provider, let current else { return }
        // The synthetic group wrapper is the ancestor of every real path, so lexical
        // containment cannot express it.
        guard node.id != current.id, current.isGroupRoot || node.path.isWithin(current.path) else { return }
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
            // Expand the folder chain so the target row exists: open collapsed folders
            // and uncover covered containers.
            collapsed.remove(folder.path)
            coveredExpanded.insert(folder.path)
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

    /// Reveal or hide one folder's unselected direct children. Returns the refresh task
    /// so callers can await the rebuilt rows deterministically.
    @discardableResult
    func toggleRevealed(_ node: FileNode) -> Task<Void, Never> {
        if revealed.contains(node.path) { revealed.remove(node.path) }
        else { revealed.insert(node.path) }
        return Task { await refresh() }
    }

    /// Expand or collapse one partially selected folder's selected children.
    func toggleCollapsed(_ node: FileNode) {
        if collapsed.contains(node.path) { collapsed.remove(node.path) }
        else { collapsed.insert(node.path) }
        lines = makeLines()
    }

    /// Expand or collapse a covered container to review its individual entries.
    func toggleCoveredExpanded(_ node: FileNode) {
        if coveredExpanded.contains(node.path) { coveredExpanded.remove(node.path) }
        else { coveredExpanded.insert(node.path) }
        lines = makeLines()
    }

    private func makeLines() -> [CleanupQueueLine] {
        let openFolder = current
        return CleanupQueueTree.lines(CleanupQueueTree.Input(
            entries: cleanup.basket, nodes: nodesByID, current: openFolder,
            directoryChildren: openFolder?.id == directoryParentID ? directoryChildren : [],
            childCounts: childCounts,
            fetchedChildren: fetchedChildren, peekChildren: peekChildren, peekCounts: peekCounts,
            revealed: revealed, collapsed: collapsed, coveredExpanded: coveredExpanded))
    }
}
