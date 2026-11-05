import Foundation
import Observation
import DiskCore

/// Owns the explicit duplicate search and its disposable, queue-independent review draft.
@MainActor @Observable final class DuplicatesViewModel {
    enum State: Equatable {
        case idle
        case searching(DuplicateProgress)
        case found(DuplicateSearch)
        case failed(String)
    }

    struct Context: Sendable {
        let index: ScanIndex
        let roots: [URL]
        let home: String
        let unusedDays: Int
        let inspectPackages: Bool
    }

    struct Presentation: Identifiable {
        let id = UUID()
    }

    private struct CopyKey: Hashable {
        let groupID: Int64
        let nodeID: Int64
    }

    private struct ProposalKey: Hashable {
        let path: String
        let keeper: String
    }

    private(set) var state: State = .idle
    private(set) var presentation: Presentation?
    private(set) var visiblePresentationID: UUID?
    private(set) var groups: [DuplicateReviewGroup] = []
    private(set) var visibleGroups: [DuplicateReviewGroup] = []
    private(set) var scopePaths: [String] = []
    private(set) var confirming = false
    private(set) var refusals: [DuplicateCommitRefusal] = []
    private(set) var proposal: [CleanupEntry] = []
    private(set) var selectedCount = 0
    private(set) var selectedBytes: Int64 = 0
    private(set) var hasUnknownSizes = false
    private(set) var hiddenSelectedCount = 0
    var focusedGroupID: Int64?
    var query = "" { didSet { if query != oldValue { updateVisibleGroups() } } }
    var filter: DuplicateReviewFilter = .all { didSet { if filter != oldValue { updateVisibleGroups() } } }
    var hideSupport = false { didSet { if hideSupport != oldValue { updateVisibleGroups() } } }
    var strategy: DuplicateKeepStrategy {
        didSet {
            defaults.set(strategy.rawValue, forKey: "duplicateKeepStrategy")
            // A new suggestion may become the keeper. Never add a check automatically.
            for group in groups where keeperOverrides[group.id] == nil {
                checked.remove(CopyKey(groupID: group.id, nodeID: group.keeper(strategy).id))
            }
            updateDraft()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = UUID()
    @ObservationIgnored private var resultIndex: ScanIndex?
    @ObservationIgnored private var groupsByID: [Int64: DuplicateReviewGroup] = [:]
    @ObservationIgnored private var visibleGroupIDs: Set<Int64> = []
    @ObservationIgnored var context: () -> Context? = { nil }
    @ObservationIgnored var apply: ([CleanupEntry], Context, @escaping @MainActor () async -> Bool) async -> DuplicateCommitOutcome = { _, _, _ in
        DuplicateCommitOutcome()
    }
    private var checked: Set<CopyKey> = []
    private var keeperOverrides: [Int64: FileNode] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        strategy = defaults.string(forKey: "duplicateKeepStrategy").flatMap(DuplicateKeepStrategy.init(rawValue:)) ?? .oldest
    }

    var searching: Bool { if case .searching = state { true } else { false } }
    var search: DuplicateSearch? { if case .found(let search) = state { search } else { nil } }
    var canConfirm: Bool { presentation != nil && !confirming && !proposal.isEmpty }
    var focusedGroup: DuplicateReviewGroup? { visibleGroups.first { $0.id == focusedGroupID } }

    func find() {
        guard !searching, presentation == nil, let context = context() else { return }
        cancel()
        let previousTask = task
        let run = run
        let strategy = strategy
        state = .searching(DuplicateProgress(stage: .comparingFiles, completed: 0, total: nil))
        let homeLibrary = context.home + "/Library"
        let exempt = CleanupRule.knownCacheRoots(home: context.home)
        let roots = context.roots
        let eligible: @Sendable (FileNode) -> Bool = { node in
            !node.path.isWithin(homeLibrary) && CleanupSafety.blockedReasonCode(node, roots: roots, exemptingCacheRoots: exempt) == nil
        }
        task = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled, self?.run == run else { return }
            let revision = await context.index.revision
            guard !Task.isCancelled, self?.matches(run, index: context.index) == true else { return }
            do {
                let result = try await DuplicateFinder.find(in: context.index, eligible: eligible) { [weak self] progress in
                    Task { @MainActor in
                        guard self?.matches(run, index: context.index) == true, self?.searching == true else { return }
                        self?.state = .searching(progress)
                    }
                }
                guard !Task.isCancelled, self?.matches(run, index: context.index) == true else { return }
                let safety = await context.index.safetyClassification(
                    home: context.home, unusedDays: context.unusedDays, inspectPackages: context.inspectPackages)
                let groups = try await DuplicateReviewGroup.sortedGroups(for: result, safety: safety, strategy: strategy)
                let liveRevision = await context.index.revision
                guard !Task.isCancelled, let self, self.matches(run, index: context.index) else { return }
                guard revision == liveRevision, result.revision == liveRevision else {
                    self.state = .failed(L10n.text("The scan changed. Find duplicates again."))
                    return
                }
                self.accept(result, groups: groups, context: context)
            } catch DuplicateSearchError.staleIndex {
                guard self?.matches(run, index: context.index) == true else { return }
                self?.state = .failed(L10n.text("The scan changed. Find duplicates again."))
            } catch is CancellationError {
                guard self?.run == run else { return }
                self?.state = .idle
            } catch {
                guard self?.matches(run, index: context.index) == true else { return }
                self?.state = .failed(L10n.format("Couldn’t find duplicates. %@", error.diagnosticDescription))
            }
        }
    }

    func cancel() {
        task?.cancel()
        run = UUID()
        presentation = nil
        confirming = false
        state = .idle
        resultIndex = nil
        groups = []
        scopePaths = []
        groupsByID = [:]
        clearDraft()
    }

    func waitForWork() async { await task?.value }

    func reopenReview() {
        guard presentation == nil, let resultIndex, let search, context()?.index === resultIndex else { return }
        task?.cancel()
        let run = run
        task = Task { [weak self] in
            let revision = await resultIndex.revision
            guard !Task.isCancelled, let self, self.matches(run, index: resultIndex) else { return }
            guard revision == search.revision else {
                self.cancel()
                return
            }
            self.presentation = Presentation()
        }
    }

    func reviewDidAppear(_ id: UUID) {
        guard presentation?.id == id else { return }
        visiblePresentationID = id
    }

    func reviewDidDisappear(_ id: UUID) {
        guard visiblePresentationID == id else { return }
        visiblePresentationID = nil
    }

    func focus(_ group: DuplicateReviewGroup) {
        guard groups.contains(where: { $0.id == group.id }) else { return }
        if !visibleGroups.contains(where: { $0.id == group.id }) {
            query = ""
            filter = .all
            hideSupport = false
        }
        focusedGroupID = group.id
    }

    func dismissReview() {
        guard !confirming else { return }
        presentation = nil
        clearDraft()
    }

    func chooseKeeper(_ node: FileNode, in group: DuplicateReviewGroup) {
        guard !confirming, presentation != nil, group.copies.contains(where: { $0.id == node.id }) else { return }
        keeperOverrides[group.id] = node
        checked.remove(CopyKey(groupID: group.id, nodeID: node.id))
        updateDraft()
    }

    func keeper(in group: DuplicateReviewGroup) -> FileNode {
        keeperOverrides[group.id] ?? group.keeper(strategy)
    }

    func isChecked(_ node: FileNode, in group: DuplicateReviewGroup) -> Bool {
        checked.contains(CopyKey(groupID: group.id, nodeID: node.id))
    }

    func canCheck(_ node: FileNode, in group: DuplicateReviewGroup) -> Bool {
        node.id != keeper(in: group).id && (!hideSupport || filter == .selected || group.support[node.id] == DuplicateReviewGroup.SupportCoverage.none)
    }

    func displayedCopies(in group: DuplicateReviewGroup) -> [FileNode] {
        guard hideSupport, filter != .selected, !group.isFolder else { return group.copies }
        return group.copies.filter { group.support[$0.id] != .all || $0.id == keeper(in: group).id }
    }

    func setChecked(_ enabled: Bool, node: FileNode, in group: DuplicateReviewGroup) {
        guard !confirming, presentation != nil else { return }
        let key = CopyKey(groupID: group.id, nodeID: node.id)
        if enabled {
            guard canCheck(node, in: group) else { return }
            checked.insert(key)
        } else {
            checked.remove(key)
        }
        updateDraft()
    }

    func selectVisible() {
        guard !confirming, presentation != nil, filter != .selected else { return }
        for group in visibleGroups {
            for node in group.copies where canCheck(node, in: group) {
                checked.insert(CopyKey(groupID: group.id, nodeID: node.id))
            }
        }
        updateDraft()
    }

    func clearVisible() {
        guard !confirming, presentation != nil else { return }
        for group in visibleGroups {
            for node in group.copies where filter == .selected || canCheck(node, in: group) {
                checked.remove(CopyKey(groupID: group.id, nodeID: node.id))
            }
        }
        updateDraft()
    }

    func confirm() {
        guard canConfirm, let context = context(), let search, resultIndex === context.index else { return }
        let run = run
        let entries = proposal
        confirming = true
        refusals = []
        task = Task { [weak self] in
            let isCurrent: @MainActor () async -> Bool = { [weak self] in
                let revision = await context.index.revision
                return !Task.isCancelled && search.revision == revision && self?.matches(run, index: context.index) == true
            }
            guard await isCurrent(), let self else {
                if self?.run == run { self?.cancel() }
                return
            }
            let outcome = await self.apply(entries, context, isCurrent)
            guard self.run == run, !Task.isCancelled else { return }
            self.confirming = false
            if outcome.succeeded {
                self.dismissReview()
            } else {
                self.refusals = outcome.refusals
            }
        }
    }

    private func matches(_ run: UUID, index: ScanIndex) -> Bool {
        self.run == run && context()?.index === index
    }

    private func accept(_ search: DuplicateSearch, groups: [DuplicateReviewGroup], context: Context) {
        resultIndex = context.index
        self.groups = groups
        groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        scopePaths = context.roots.map { canonicalURL($0).path }
        state = .found(search)
        updateVisibleGroups()
        presentation = Presentation()
    }

    private func clearDraft() {
        checked = []
        keeperOverrides = [:]
        refusals = []
        query = ""
        filter = .all
        hideSupport = false
        focusedGroupID = nil
        updateDraft()
        updateVisibleGroups()
    }

    private func updateDraft() {
        refusals = []
        var seen: Set<ProposalKey> = []
        var unique: Set<String> = []
        var entries: [CleanupEntry] = []
        var bytes: Int64 = 0
        var unknown = false
        let selectedByGroup = Dictionary(grouping: checked, by: \.groupID)
        for groupID in selectedByGroup.keys.sorted() {
            guard let group = groupsByID[groupID], let selections = selectedByGroup[groupID] else { continue }
            let selectedIDs = Set(selections.map(\.nodeID))
            let kept = keeper(in: group)
            for node in group.copies where selectedIDs.contains(node.id) {
                for entry in group.entries(copy: node, keeper: kept) {
                    guard let keeper = entry.survivor,
                          seen.insert(ProposalKey(path: entry.node.path, keeper: keeper.path)).inserted else { continue }
                    entries.append(entry)
                    if unique.insert(entry.node.path).inserted {
                        bytes += entry.node.knownSize(for: .allocated)
                        unknown = unknown || entry.node.unknownAllocatedCount > 0
                    }
                }
            }
        }
        proposal = entries
        selectedCount = unique.count
        selectedBytes = bytes
        hasUnknownSizes = unknown
        if filter == .selected { updateVisibleGroups() } else { updateHiddenSelection() }
    }

    private func updateVisibleGroups() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedGroups = Set(checked.map(\.groupID))
        visibleGroups = groups.filter { group in
            if filter == .selected { return selectedGroups.contains(group.id) }
            if filter == .files, group.isFolder { return false }
            if filter == .folders, !group.isFolder { return false }
            if hideSupport, group.copies.allSatisfy({ group.support[$0.id] == .all }) { return false }
            return term.isEmpty || group.copies.contains { $0.path.localizedStandardContains(term) }
        }
        visibleGroupIDs = Set(visibleGroups.map(\.id))
        if !visibleGroups.contains(where: { $0.id == focusedGroupID }) { focusedGroupID = visibleGroups.first?.id }
        updateHiddenSelection()
    }

    private func updateHiddenSelection() {
        guard !checked.isEmpty, filter != .selected else { hiddenSelectedCount = 0; return }
        var shown: Set<String> = []
        for selection in checked where visibleGroupIDs.contains(selection.groupID) {
            guard let group = groupsByID[selection.groupID],
                  let node = group.copies.first(where: { $0.id == selection.nodeID }),
                  group.isFolder || canCheck(node, in: group) else { continue }
            shown.formUnion(group.files(in: node).map(\.path))
        }
        hiddenSelectedCount = selectedCount - shown.count
    }
}
