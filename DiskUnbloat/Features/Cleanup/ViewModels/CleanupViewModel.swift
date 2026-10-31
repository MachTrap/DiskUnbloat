import Foundation
import Observation
import DiskCore

@MainActor @Observable final class CleanupViewModel {
    @ObservationIgnored private let activity: any ApplicationActivityProviding
    private let homePath: String
    @ObservationIgnored private let service: any CleanupServing
    private(set) var cleaning = false
    var basket: [FileNode] = []
    var showBasket = false
    private(set) var results: [CleanupResult] = []

    init(service: any CleanupServing, homePath: String = LocationCatalog().home.path, activity: any ApplicationActivityProviding = ApplicationActivityService()) {
        self.service = service; self.homePath = homePath; self.activity = activity
    }

    /// Refusal message when a node overlaps a running application's active cache. Static so the
    /// `execute` preflight (a `@Sendable` closure) can reuse it without capturing `self`.
    private static func activityMessage(_ node: FileNode, activity: any ApplicationActivityProviding, home: String) -> String? {
        if activity.blockedCachePaths(home: home).contains(where: { node.path.overlaps($0) }) {
            return L10n.text("This selection includes cache data belonging to a running application or protected service. Close the application and review again.")
        }
        return nil
    }

    private func activityReason(_ node: FileNode) -> String? {
        Self.activityMessage(node, activity: activity, home: homePath)
    }

    func reset(preservingReport: Bool = false) {
        basket = []
        if !preservingReport { results = [] }
    }

    func add(_ node: FileNode, root: URL) -> String? { add(node, roots: [root]) }

    func add(_ node: FileNode, roots: [URL]) -> String? {
        guard !roots.isEmpty else { return L10n.text(CleanupReason.outsideScope.message) }
        if let reason = activityReason(node) { return reason }
        if let reason = CleanupSafety.blockedReasonCode(node, roots: roots, exemptingCacheRoots: CleanupRule.knownCacheRoots(home: homePath)) { return L10n.text(reason.message) }
        basket = CleanupPlan(roots: roots, items: basket + [node], mode: .trash, knownCacheRoots: CleanupRule.knownCacheRoots(home: homePath)).items
        return nil
    }

    func invalidate(overlapping path: String) -> Int {
        let previous = basket.count
        basket.removeAll { $0.path.overlaps(path) }
        return previous - basket.count
    }

    func removeFromBasket(_ node: FileNode) {
        guard !cleaning else { return }
        basket.removeAll { $0.id == node.id }
    }

    /// Called synchronously to disable repeated submissions before creating an async task.
    func begin() -> [FileNode]? {
        guard !cleaning, !basket.isEmpty else { return nil }
        cleaning = true
        return basket
    }

    func execute(_ items: [FileNode], root: URL, index: ScanIndex, mode: CleanupMode) async -> Bool {
        await execute(items, roots: [root], index: index, mode: mode)
    }

    func execute(_ items: [FileNode], roots: [URL], index: ScanIndex, mode: CleanupMode) async -> Bool {
        guard !roots.isEmpty else { return false }
        defer { cleaning = false }
        var eligible: [FileNode] = []
        var refused: [CleanupResult] = []
        for node in items {
            if let reason = activityReason(node) { refused.append(CleanupResult(id: node.id,path: node.path,succeeded: false,message: reason)) }
            else { eligible.append(node) }
        }
        let ancestors = await index.ancestorIdentities(for: items.map(\.id))
        let activity = self.activity; let home = homePath
        let plan = CleanupPlan(roots: roots, items: eligible, mode: mode, ancestorIdentities: ancestors, preflight: { node in
            await MainActor.run { CleanupViewModel.activityMessage(node, activity: activity, home: home) }
        }, knownCacheRoots: CleanupRule.knownCacheRoots(home: homePath))
        results = refused + (await service.execute(plan))
        return results.contains(where: \.succeeded)
    }
}
