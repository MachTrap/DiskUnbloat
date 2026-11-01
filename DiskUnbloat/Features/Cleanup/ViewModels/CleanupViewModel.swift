import Foundation
import Observation
import DiskCore

@MainActor @Observable final class CleanupViewModel {
    @ObservationIgnored private let activity: any ApplicationActivityProviding
    private let homePath: String
    @ObservationIgnored private let service: any CleanupServing
    private(set) var cleaning = false
    /// Canonical deletion queue: normalized, topmost entries kept, disjoint subtrees.
    var basket: [CleanupEntry] = [] { didSet { if basket != oldValue { queueRevision += 1 } } }
    /// Bumped on every queue mutation so derived views can rebuild asynchronously.
    private(set) var queueRevision = 0
    var showQueue = false
    /// Presents the per-item report after a completed cleanup run.
    var showReport = false
    private(set) var results: [CleanupResult] = []

    /// Estimated on-disk bytes of the normalized queue, using the same known-size
    /// accounting the map subtracts when queued items disappear. An estimate, not a
    /// promise of reclaimed space.
    var estimatedBytes: Int64 { basket.reduce(0) { $0 + $1.node.knownSize(for: .allocated) } }
    var hasUnknownSizes: Bool { basket.contains { $0.node.unknownAllocatedCount > 0 } }

    init(service: any CleanupServing, homePath: String = LocationCatalog().home.path, activity: any ApplicationActivityProviding = ApplicationActivityService()) {
        self.service = service; self.homePath = homePath; self.activity = activity
    }

    /// Refusal message when a path overlaps a running application's active cache. Static so the
    /// `execute` preflight (a `@Sendable` closure) can reuse it without capturing `self`.
    private static func activityMessage(_ path: String, activity: any ApplicationActivityProviding, home: String) -> String? {
        if activity.blockedCachePaths(home: home).contains(where: { path.overlaps($0) }) {
            return L10n.text("This selection includes cache data belonging to a running application or protected service. Close the application and review again.")
        }
        return nil
    }

    private func activityReason(_ node: FileNode) -> String? {
        Self.activityMessage(node.path, activity: activity, home: homePath)
    }

    /// Weaker refusal for a kept scan-root folder: only the folder itself (or a folder below an
    /// active cache) is refused. Active caches among its contents are rechecked per child before
    /// each removal at execution time, so an always-protected cache inside the root cannot block
    /// cleaning the whole location.
    private func rootActivityReason(_ node: FileNode) -> String? {
        if activity.blockedCachePaths(home: homePath).contains(where: { node.path.isWithin($0) }) {
            return activityReason(node)
        }
        return nil
    }

    func reset(preservingReport: Bool = false) {
        basket = []
        if !preservingReport { results = [] }
    }

    func add(_ node: FileNode, root: URL) -> String? { add(node, roots: [root]) }

    func add(_ node: FileNode, roots: [URL]) -> String? {
        guard !roots.isEmpty else { return L10n.text(CleanupReason.outsideScope.message) }
        let cacheRoots = CleanupRule.knownCacheRoots(home: homePath)
        let removeReason = CleanupSafety.blockedReasonCode(node, roots: roots, exemptingCacheRoots: cacheRoots)
        let emptyReason = CleanupSafety.emptyContentsBlockedReasonCode(node, roots: roots, exemptingCacheRoots: cacheRoots)
        let operation: CleanupOperation
        if removeReason == nil {
            if let reason = activityReason(node) { return reason }
            operation = .remove
        } else if emptyReason == nil {
            // A scan-root folder cannot be removed, but its contents can be cleaned in place.
            if let reason = rootActivityReason(node) { return reason }
            operation = .emptyContents
        } else {
            // For scan roots the empty-contents check names the specific protection that
            // still applies (managed data, system tree, volume root) instead of the generic
            // "roots cannot be removed" refusal.
            let reason = removeReason == .scanRoot ? emptyReason : removeReason
            return L10n.text((reason ?? .scanRoot).message)
        }
        basket = CleanupPlan(roots: roots, entries: basket + [CleanupEntry(node: node, operation: operation)], mode: .trash, knownCacheRoots: cacheRoots).items
        return nil
    }

    func invalidate(overlapping path: String) -> Int {
        let previous = basket.count
        basket.removeAll { $0.node.path.overlaps(path) }
        return previous - basket.count
    }

    func removeFromBasket(_ node: FileNode) {
        guard !cleaning else { return }
        basket.removeAll { $0.node.id == node.id }
    }

    /// Remove every queue entry overlapping a path: the exact entry, entries below it,
    /// or entries above it when the row is covered by a selected folder.
    func deselect(_ node: FileNode) {
        guard !cleaning else { return }
        basket.removeAll { $0.node.path.overlaps(node.path) }
    }

    /// How a node relates to the queue, for context-menu wording.
    func membership(_ node: FileNode) -> QueueMembership {
        queueMembership(path: node.path, queuedPaths: basket.map { $0.node.path })
    }

    /// Called synchronously to disable repeated submissions before creating an async task.
    func begin() -> [CleanupEntry]? {
        guard !cleaning, !basket.isEmpty else { return nil }
        cleaning = true
        return basket
    }

    func execute(_ items: [CleanupEntry], root: URL, index: ScanIndex, mode: CleanupMode) async -> Bool {
        await execute(items, roots: [root], index: index, mode: mode)
    }

    func execute(_ items: [CleanupEntry], roots: [URL], index: ScanIndex, mode: CleanupMode) async -> Bool {
        guard !roots.isEmpty else { return false }
        defer { cleaning = false }
        var eligible: [CleanupEntry] = []
        var refused: [CleanupResult] = []
        for entry in items {
            let reason = entry.operation == .remove ? activityReason(entry.node) : rootActivityReason(entry.node)
            if let reason { refused.append(CleanupResult(id: entry.node.id,path: entry.node.path,succeeded: false,message: reason)) }
            else { eligible.append(entry) }
        }
        let ancestors = await index.ancestorIdentities(for: items.map { $0.node.id })
        let activity = self.activity; let home = homePath
        let plan = CleanupPlan(roots: roots, entries: eligible, mode: mode, ancestorIdentities: ancestors, preflight: { path in
            await MainActor.run { CleanupViewModel.activityMessage(path, activity: activity, home: home) }
        }, knownCacheRoots: CleanupRule.knownCacheRoots(home: homePath))
        results = refused + (await service.execute(plan))
        return results.contains(where: \.succeeded)
    }
}
