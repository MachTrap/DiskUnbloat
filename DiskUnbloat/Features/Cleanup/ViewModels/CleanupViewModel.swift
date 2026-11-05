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

struct DuplicateCommitRefusal: Identifiable, Equatable {
    let path: String
    let reason: String
    var id: String { path }
}

struct DuplicateCommitOutcome {
    var added = 0
    var alreadyQueued = 0
    var refusals: [DuplicateCommitRefusal] = []
    var succeeded: Bool { refusals.isEmpty }
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
    @ObservationIgnored private var committingReviewedDuplicates = false
    private(set) var cleaning = false
    /// Canonical deletion queue: normalized, topmost entries kept, disjoint subtrees.
    var basket: [CleanupEntry] = [] {
        didSet {
            guard basket != oldValue else { return }
            queueRevision += 1
            autoSelectedPaths.formIntersection(basket.map(\.node.path))
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
    /// The last run's mode and the known on-disk bytes of its succeeded entries. Moved
    /// items still occupy the disk until the user empties the Trash; the report says so.
    private(set) var lastRunMode: CleanupMode = .trash
    private(set) var lastRunBytes: Int64 = 0

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
        addSelection(node, roots: roots, clearingOnRefusal: true)
    }

    func add(_ node: FileNode, roots: [URL]) -> String? {
        addSelection(node, roots: roots, clearingOnRefusal: false)
    }

    private func addSelection(_ node: FileNode, roots: [URL], clearingOnRefusal: Bool) -> String? {
        guard !cleaning, !roots.isEmpty else { return L10n.text(CleanupReason.outsideScope.message) }
        if basket.contains(where: { $0.survivor != nil }),
           let conflict = CleanupPlan.duplicateConflicts(in: basket + [CleanupEntry(node: node, operation: .remove)])[node.path] {
            return L10n.text(conflict.message)
        }
        let cacheRoots = exemptRoots
        let resolved = resolvedOperation(for: node, roots: roots, cacheRoots: cacheRoots, blockedCaches: activity.blockedCachePaths(home: homePath))
        if let operation = resolved.operation {
            basket = CleanupPlan(roots: roots, entries: basket + [CleanupEntry(node: node, operation: operation)], mode: .trash, knownCacheRoots: cacheRoots).items
            return nil
        }
        if clearingOnRefusal, let refusal = resolved.refusal,
           basket.contains(where: { $0.node.path.overlaps(node.path) }) {
            deselect(node)
            return refusal + " " + L10n.text("The items already selected inside it were removed from the cleanup queue instead.")
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
    func applyAutoSelection(_ result: AutoSelectionResult, roots: [URL]) -> AutoSelectionApplyOutcome {
        guard !cleaning, !roots.isEmpty else { return AutoSelectionApplyOutcome() }
        // The new recommendation's exemptions replace the previous one's, except where a
        // manually kept entry still lies inside an earlier exemption.
        let manual = basket.filter { !autoSelectedPaths.contains($0.node.path) }
        let manualPaths = Set(manual.map(\.node.path))
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
                    entries.append(CleanupEntry(node: node, operation: operation))
                } else {
                    outcome.skipped += 1
                }
            }
        }
        if manual.contains(where: { $0.survivor != nil }) {
            let conflicts = CleanupPlan.duplicateConflicts(in: manual + entries)
            let proposedCount = entries.count
            entries.removeAll { conflicts[$0.node.path] != nil }
            outcome.skipped += proposedCount - entries.count
        }
        outcome.applied = entries.count
        basket = CleanupPlan(roots: roots, entries: manual + entries, mode: .trash, knownCacheRoots: cacheRoots).items
        let proposedPaths = Set(entries.map(\.node.path))
        autoSelectedPaths = Set(basket.map(\.node.path)).intersection(proposedPaths).subtracting(manualPaths)
        return outcome
    }

    /// Commits the complete reviewed batch or returns the individual refusals.
    /// Confirmation never performs a filesystem mutation.
    func commitReviewedDuplicates(
        _ entries: [CleanupEntry], roots: [URL], index: ScanIndex,
        isCurrent: @MainActor () async -> Bool
    ) async -> DuplicateCommitOutcome {
        let stale = DuplicateCommitOutcome(refusals: [
            .init(path: entries.first?.node.path ?? "",
                  reason: L10n.text("The scan or cleanup queue changed during review. Review the current selection and try again."))
        ])
        guard !entries.isEmpty, !roots.isEmpty, !cleaning, !committingReviewedDuplicates else { return stale }
        committingReviewedDuplicates = true
        defer { committingReviewedDuplicates = false }
        let revision = queueRevision
        let evidence = await CleanupService.validateReviewedDuplicates(entries, roots: roots, index: index)
        guard await isCurrent(), !Task.isCancelled, !cleaning, revision == queueRevision else { return stale }

        // A duplicate review uses ordinary cleanup rules, without exemptions
        // contributed by the previous recommendation.
        let cacheRoots = CleanupRule.knownCacheRoots(home: homePath)
        let blockedCaches = activity.blockedCachePaths(home: homePath)
        let existingPaths = Set(basket.map(\.node.path))
        let plan = CleanupPlan(roots: roots, entries: basket + entries, mode: .trash, knownCacheRoots: cacheRoots)
        var outcome = DuplicateCommitOutcome()
        var processed: Set<String> = []
        for entry in entries where processed.insert(entry.node.path).inserted {
            let path = entry.node.path
            if let reason = plan.duplicateRefusals[path] ?? evidence[path] {
                outcome.refusals.append(.init(path: path, reason: L10n.text(reason.message)))
                continue
            }
            let resolved = resolvedOperation(for: entry.node, roots: roots, cacheRoots: cacheRoots, blockedCaches: blockedCaches)
            guard entry.operation == .remove, resolved.operation == .remove, entry.survivor != nil else {
                let reason = resolved.refusal ?? L10n.text(DuplicateCleanupRefusal.invalidPair.message)
                outcome.refusals.append(.init(path: path, reason: reason))
                continue
            }
            if existingPaths.contains(path) { outcome.alreadyQueued += 1 }
        }
        guard outcome.succeeded else { return outcome }
        outcome.added = plan.items.count - basket.count
        basket = plan.items
        showQueue = true
        return outcome
    }

    func invalidate(overlapping path: String) -> Int {
        let previous = basket.count
        basket.removeAll { $0.node.path.overlaps(path) || $0.survivor?.path.overlaps(path) == true }
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
        let ancestors = await index.cleanupAncestorIdentities(for: items)
        let activity = self.activity; let home = homePath
        let recorder = diagnostics
        // Activity refusals must not hide an invalid dependency in the original queue.
        let conflictingQueue = !CleanupPlan.duplicateConflicts(in: items).isEmpty
        let plan = CleanupPlan(roots: roots, entries: conflictingQueue ? items : eligible, mode: mode, ancestorIdentities: ancestors, preflight: { path in
            await MainActor.run { CleanupViewModel.activityMessage(path, activity: activity, home: home) }
        }, knownCacheRoots: exemptRoots, diagnostics: { recorder.event($0) })
        results = (conflictingQueue ? [] : refused) + (await service.execute(plan))
        let succeeded = Set(results.filter(\.succeeded).map(\.id))
        lastRunMode = mode
        lastRunBytes = plan.items.filter { succeeded.contains($0.node.id) }.reduce(0) { $0 + $1.node.knownSize(for: .allocated) }
        diagnostics.runFinished(succeeded: results.filter(\.succeeded).count, failed: results.count - results.filter(\.succeeded).count)
        return results.contains(where: \.succeeded)
    }
}
