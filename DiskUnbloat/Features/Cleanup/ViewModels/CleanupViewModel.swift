import Foundation
import Observation
import DiskCore

/// Result of applying one automatic selection to the deletion queue.
struct AutoSelectionApplyOutcome: Sendable, Equatable {
    /// Items the recommendation queued.
    var applied = 0
    /// Proposed items refused by safety checks or running-application caches.
    var skipped = 0
}

@MainActor @Observable final class CleanupViewModel {
    @ObservationIgnored private let activity: any ApplicationActivityProviding
    private let homePath: String
    @ObservationIgnored private let service: any CleanupServing
    /// The run's audit trail writer; tests and previews inject the no-op so nothing
    /// touches the filesystem there.
    @ObservationIgnored private let diagnostics: any CleanupDiagnosticRecording
    /// Fired on every queue change with the new entries; injected by the workspace so the
    /// explorer always learns the hidden paths — the queue is normalized inside
    /// `didSet`, and no view must be relied on as a relay for that handoff.
    @ObservationIgnored var basketDidUpdate: (([CleanupEntry]) -> Void)?
    private(set) var cleaning = false
    /// Canonical deletion queue: normalized, topmost entries kept, disjoint subtrees.
    var basket: [CleanupEntry] = [] {
        didSet {
            guard basket != oldValue else { return }
            queueRevision += 1
            recomputeBasketAttributes()
            membershipIndex = QueueMembershipIndex(entries: basket)
            basketDidUpdate?(basket)
        }
    }
    /// Paths contributed by the last automatic selection, so a fresh recommendation
    /// replaces the previous one while manually picked items stay untouched.
    @ObservationIgnored private var autoSelectedPaths: Set<String> = []
    /// Exact folders a deep recommendation selected under managed data (older app
    /// versions' settings). Only these paths — never their parents or siblings — are
    /// exempt, and only while queued items still refer to them.
    @ObservationIgnored private var selectionExemptions: Set<String> = []
    /// Curated cache roots plus the current recommendation's exact exemptions.
    private var exemptRoots: [String] { CleanupRule.knownCacheRoots(home: homePath) + selectionExemptions.sorted() }
    /// Bumped on every queue mutation so derived views can rebuild asynchronously.
    private(set) var queueRevision = 0
    var showQueue = false
    /// Presents the per-item report after a completed cleanup run.
    var showReport = false
    private(set) var results: [CleanupResult] = []

    /// Estimated on-disk bytes of the normalized queue, using the same known-size
    /// accounting the map subtracts when queued items disappear. An estimate, not a
    /// promise of reclaimed space. Recomputed once per queue change.
    private(set) var estimatedBytes: Int64 = 0
    private(set) var hasUnknownSizes = false
    /// Fast membership for rows and map tiles; rebuilt once per queue change.
    private(set) var membershipIndex: QueueMembershipIndex = QueueMembershipIndex(entries: [])
    private func recomputeBasketAttributes() {
        estimatedBytes = basket.reduce(0) { $0 + $1.node.knownSize(for: .allocated) }
        hasUnknownSizes = basket.contains { $0.node.unknownAllocatedCount > 0 }
    }

    init(service: any CleanupServing, homePath: String = LocationCatalog().home.path, activity: any ApplicationActivityProviding = ApplicationActivityService(), diagnostics: any CleanupDiagnosticRecording = NullCleanupDiagnostics()) {
        self.service = service; self.homePath = homePath; self.activity = activity; self.diagnostics = diagnostics
    }

    /// Refusal message when a path overlaps a running application's active cache. Static so the
    /// `execute` preflight (a `@Sendable` closure) can reuse it without capturing `self`.
    private static func activityMessage(_ path: String, activity: any ApplicationActivityProviding, home: String) -> String? {
        activityMessage(path, blockedCaches: activity.blockedCachePaths(home: home))
    }

    private static func activityMessage(_ path: String, blockedCaches: [String]) -> String? {
        if blockedCaches.contains(where: { path.overlaps($0) }) {
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
        autoSelectedPaths = []
        selectionExemptions = []
        if !preservingReport { results = [] }
    }

    /// Clear the selection: every queued item leaves, manual and recommended alike,
    /// while the last operation's report stays. The next recommendation starts fresh.
    func clearSelection() {
        guard !cleaning else { return }
        basket = []
        autoSelectedPaths = []
        selectionExemptions = []
    }

    func add(_ node: FileNode, root: URL) -> String? { add(node, roots: [root]) }

    /// The checkbox/tile select intent: add the whole folder, or — when that is refused
    /// and the folder already carries queue entries (a partial row like ~/Library/Caches
    /// with a nested queued cache) — clear the nested selection instead so the click
    /// always stays an honest action. Returns a message to show: the refusal alone, or
    /// the refusal plus what happened to the nested entries; nil on success.
    func addOrClear(_ node: FileNode, roots: [URL]) -> String? {
        if let refusal = add(node, roots: roots) {
            let nested = basket.filter { $0.node.path.overlaps(node.path) }
            guard !nested.isEmpty else { return refusal }
            deselect(node)
            return refusal + " " + L10n.text("The items already selected inside it were removed from the cleanup queue instead.")
        }
        return nil
    }

    func add(_ node: FileNode, roots: [URL]) -> String? {
        guard !roots.isEmpty else { return L10n.text(CleanupReason.outsideScope.message) }
        let cacheRoots = exemptRoots
        let resolved = resolvedOperation(for: node, roots: roots, cacheRoots: cacheRoots, blockedCaches: activity.blockedCachePaths(home: homePath))
        if let operation = resolved.operation {
            basket = CleanupPlan(roots: roots, entries: basket + [CleanupEntry(node: node, operation: operation)], mode: .trash, knownCacheRoots: cacheRoots).items
            return nil
        }
        return resolved.refusal
    }

    /// The one mapping from a selected node to its queue operation: removal where allowed,
    /// "clean contents, keep folder" for scan roots, and a refusal message otherwise.
    /// Manual selection and automatic selection share it, so both agree on every
    /// protection: scan roots are never removed, `/` and volume roots stay refused, and
    /// managed data is blocked except for the exact curated cache locations.
    private func resolvedOperation(
        for node: FileNode, roots: [URL], cacheRoots: [String], blockedCaches: [String]
    ) -> (operation: CleanupOperation?, refusal: String?) {
        let removeReason = CleanupSafety.blockedReasonCode(node, roots: roots, exemptingCacheRoots: cacheRoots)
        let emptyReason = CleanupSafety.emptyContentsBlockedReasonCode(node, roots: roots, exemptingCacheRoots: cacheRoots)
        if removeReason == nil {
            if let reason = Self.activityMessage(node.path, blockedCaches: blockedCaches) { return (nil, reason) }
            return (.remove, nil)
        }
        if emptyReason == nil {
            // A scan-root folder cannot be removed, but its contents can be cleaned in place.
            if blockedCaches.contains(where: { node.path.isWithin($0) }) {
                return (nil, Self.activityMessage(node.path, blockedCaches: blockedCaches) ?? "")
            }
            return (.emptyContents, nil)
        }
        // For scan roots the empty-contents check names the specific protection that
        // still applies (managed data, system tree, volume root) instead of the generic
        // "roots cannot be removed" refusal.
        let reason = removeReason == .scanRoot ? emptyReason : removeReason
        return (nil, L10n.text((reason ?? .scanRoot).message))
    }

    /// Applies one automatic selection: every proposed node passes the same checks as
    /// manual selection (refusals are counted, never forced), a fully covered scan root
    /// collapses to one emptied entry, and a fresh recommendation replaces the previous
    /// one while manual picks stay.
    /// `keepsGroupLocation`: duplicate sets, where each group's location is the copy being
    /// kept; every queued copy records it as the survivor cleanup re-verifies.
    func applyAutoSelection(_ result: AutoSelectionResult, roots: [URL], keepsGroupLocation: Bool = false) -> AutoSelectionApplyOutcome {
        guard !cleaning, !roots.isEmpty else { return AutoSelectionApplyOutcome() }
        // The new recommendation's exemptions replace the previous one's, except where a
        // manually kept entry still lies inside an earlier exemption.
        let manualPaths = basket.filter { !autoSelectedPaths.contains($0.node.path) }.map(\.node.path)
        selectionExemptions = result.exemptPaths.union(selectionExemptions.filter { exempt in manualPaths.contains { $0.isWithin(exempt) } })
        let cacheRoots = exemptRoots
        let blockedCaches = activity.blockedCachePaths(home: homePath)
        let rootPaths = Set(roots.map { canonicalURL($0).path })
        var entries: [CleanupEntry] = []
        var outcome = AutoSelectionApplyOutcome()
        for group in result.groups {
            let proposed: [FileNode] = group.coversAllChildren && rootPaths.contains(group.location.path)
                ? [group.location]
                : group.nodes
            for node in proposed {
                let resolved = resolvedOperation(for: node, roots: roots, cacheRoots: cacheRoots, blockedCaches: blockedCaches)
                if let operation = resolved.operation {
                    entries.append(CleanupEntry(node: node, operation: operation,
                                                survivor: keepsGroupLocation ? CleanupEntry.Survivor(group.location) : nil))
                } else {
                    outcome.skipped += 1
                }
            }
        }
        outcome.applied = entries.count
        let manual = basket.filter { !autoSelectedPaths.contains($0.node.path) }
        basket = CleanupPlan(roots: roots, entries: manual + entries, mode: .trash, knownCacheRoots: cacheRoots).items
        autoSelectedPaths = Set(entries.map { $0.node.path })
        return outcome
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

    /// How a node relates to the queue, for context-menu wording — an O(depth) walk over
    /// the rebuild-per-queue-change index, never a linear scan per render.
    func membership(_ node: FileNode) -> QueueMembership {
        membershipIndex.membership(of: node.path)
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
        diagnostics.runStarted(mode: mode, roots: roots.map { canonicalURL($0).path },
                               items: items.map { (path: $0.node.path, operation: String(describing: $0.operation)) })
        var eligible: [CleanupEntry] = []
        var refused: [CleanupResult] = []
        for entry in items {
            let reason = entry.operation == .remove ? activityReason(entry.node) : rootActivityReason(entry.node)
            if let reason {
                refused.append(CleanupResult(id: entry.node.id,path: entry.node.path,succeeded: false,message: reason))
                diagnostics.refused(path: entry.node.path, message: reason)
            }
            else { eligible.append(entry) }
        }
        let ancestors = await index.ancestorIdentities(for: items.map { $0.node.id })
        let activity = self.activity; let home = homePath
        let recorder = diagnostics
        let plan = CleanupPlan(roots: roots, entries: eligible, mode: mode, ancestorIdentities: ancestors, preflight: { path in
            await MainActor.run { CleanupViewModel.activityMessage(path, activity: activity, home: home) }
        }, knownCacheRoots: exemptRoots, diagnostics: { recorder.event($0) })
        results = refused + (await service.execute(plan))
        diagnostics.runFinished(succeeded: results.filter(\.succeeded).count, failed: results.count - results.filter(\.succeeded).count)
        return results.contains(where: \.succeeded)
    }
}
