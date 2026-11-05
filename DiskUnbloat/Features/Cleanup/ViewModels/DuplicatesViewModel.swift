import Foundation
import Observation
import DiskCore

/// Duplicate detection for the quick-select panel. Finding reads file contents, so it is
/// an explicit step; selecting goes through the same queue rules as every quick-select
/// level (refusals counted, never forced) and records each set's kept copy, which
/// cleanup re-verifies before removing any other copy.
@MainActor @Observable final class DuplicatesViewModel {
    enum State: Equatable {
        case idle
        case searching(completed: Int, total: Int)
        case found(DuplicateSearch)
        case failed(String)
    }

    struct Context { let index: ScanIndex; let roots: [URL]; let home: String }

    private(set) var state: State = .idle
    var strategy: DuplicateKeepStrategy {
        didSet { defaults.set(strategy.rawValue, forKey: "duplicateKeepStrategy") }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The current scan, or `nil` when cleanup is unavailable (cancelled scan, busy).
    @ObservationIgnored var context: () -> Context? = { nil }
    /// Queues a result through the cleanup model; returns the apply outcome.
    @ObservationIgnored var apply: (AutoSelectionResult) -> AutoSelectionApplyOutcome = { _ in AutoSelectionApplyOutcome() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        strategy = defaults.string(forKey: "duplicateKeepStrategy").flatMap(DuplicateKeepStrategy.init(rawValue:)) ?? .oldest
    }

    var searching: Bool { if case .searching = state { true } else { false } }
    var search: DuplicateSearch? { if case .found(let search) = state { search } else { nil } }

    func find() {
        guard !searching, let context = context() else { return }
        task?.cancel()
        state = .searching(completed: 0, total: 0)
        let exempt = CleanupRule.knownCacheRoots(home: context.home)
        let library = context.home + "/Library"
        let roots = context.roots
        // User files only: nothing protected, nothing inside ~/Library (app data).
        let eligible: @Sendable (FileNode) -> Bool = { node in
            !node.path.isWithin(library) && CleanupSafety.blockedReasonCode(node, roots: roots, exemptingCacheRoots: exempt) == nil
        }
        task = Task {
            do {
                let result = try await DuplicateFinder.find(in: context.index, eligible: eligible) { [weak self] completed, total in
                    Task { @MainActor in if self?.searching == true { self?.state = .searching(completed: completed, total: total) } }
                }
                guard !Task.isCancelled else { return }
                state = .found(result)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel(); task = nil; state = .idle }

    /// Called whenever the scan changes: results describe an index that no longer exists.
    func reset() { cancel() }

    @discardableResult
    func select() -> AutoSelectionApplyOutcome? {
        guard let search, !search.sets.isEmpty else { return nil }
        return apply(search.result(strategy))
    }
}
