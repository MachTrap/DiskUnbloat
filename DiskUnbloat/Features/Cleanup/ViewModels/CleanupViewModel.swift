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

    private func activityReason(_ node: FileNode) -> String? {
        if activity.blockedCachePaths(home: homePath).contains(where: { node.path == $0 || node.path.hasPrefix($0 + "/") || $0.hasPrefix(node.path + "/") }) {
            return L10n.text("This selection includes cache data belonging to a running application or protected service. Close the application and review again.")
        }
        return nil
    }

    func reset(preservingReport: Bool = false) {
        basket = []
        if !preservingReport { results = [] }
    }

    func add(_ node: FileNode, root: URL) -> String? {
        if let reason = activityReason(node) { return reason }
        if let reason = CleanupSafety.blockedReasonCode(node, root: root) { return L10n.text(reason.message) }
        basket = CleanupPlan(root: root, items: basket + [node], mode: .trash).items
        return nil
    }

    func invalidate(overlapping path: String) -> Int {
        let previous = basket.count
        basket.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") || path.hasPrefix($0.path + "/") }
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
        defer { cleaning = false }
        var eligible: [FileNode] = []
        var refused: [CleanupResult] = []
        for node in items {
            if let reason = activityReason(node) { refused.append(CleanupResult(id: node.id,path: node.path,succeeded: false,message: reason)) }
            else { eligible.append(node) }
        }
        let ancestors = await index.ancestorIdentities(for: items.map(\.id))
        let activity = self.activity; let home = homePath
        let plan = CleanupPlan(root: root, items: eligible, mode: mode, ancestorIdentities: ancestors, preflight: { node in
            await MainActor.run {
                if activity.blockedCachePaths(home: home).contains(where: { node.path == $0 || node.path.hasPrefix($0 + "/") || $0.hasPrefix(node.path + "/") }) {
                    return L10n.text("This selection includes cache data belonging to a running application or protected service. Close the application and review again.")
                }
                return nil
            }
        })
        results = refused + (await service.execute(plan))
        return results.contains(where: \.succeeded)
    }
}
