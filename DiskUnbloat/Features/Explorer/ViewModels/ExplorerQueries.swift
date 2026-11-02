import Foundation
import DiskCore

/// Everything that affects the map scene and its legend for one explorer state.
/// Deliberately excludes the running-application cache exclusions, so suggestion
/// results (which depend on them) are never cached.
struct ExplorerQueries {
    let current: FileNode?
    let metric: SizeMetric
    let options: ScanOptions
    let scope: ExplorerScope
    let suggestion: Suggestion?
    /// Queued deletion items hidden from the map.
    let hiddenPaths: [String]
    /// Containers whose every child is queued; their descendants hide, the folder stays.
    var hiddenSubtrees: [String] = []
    /// Running-application cache exclusions; empty unless a suggestion is active.
    let activityExclusions: [String]
    let search: String
    let minimumGB: Double
    let olderDays: Int
    let extensionFilter: String
    let cacheRootPath: String?
    let homePath: String?
    let cacheAgeDays: Int
    let ageDays: Int
    let largeGB: Double
    let groupScan: Bool

    var hasFilters: Bool {
        !search.isEmpty || suggestion != nil || minimumGB > 0 || olderDays > 0 || !extensionFilter.isEmpty
    }

    func subtreeScope() -> String? {
        guard scope == .current, let current else { return nil }
        return groupScan && current.isGroupRoot ? nil : current.path
    }

    /// The map's own query: direct children of the current folder when unfiltered,
    /// matching leaf entries in scope when any filter narrows the scene.
    func sceneQuery() -> FileQuery {
        var q = FileQuery()
        q.inspectPackages = options.inspectPackages
        q.metric = metric
        if hasFilters {
            q.leafResults = true
            if scope == .current { q.subtreePath = subtreeScope() }
        } else {
            q.parentID = current?.id
        }
        if let suggestion {
            q.cleanupRule = suggestion.rule
            q.userHome = homePath
            q.cacheAgeDays = cacheAgeDays
            q.excludedCandidatePaths = activityExclusions
        }
        q.hiddenPaths = hiddenPaths
        q.hiddenSubtrees = hiddenSubtrees
        q.search = search; q.minimumSize = Int64(max(0, minimumGB) * 1e9)
        q.olderThan = olderDays > 0 ? Date().addingTimeInterval(-Double(olderDays) * 86400) : nil
        q.fileExtension = extensionFilter
        q.cacheRootPath = cacheRootPath
        q.largeThreshold = Int64(max(0.001, largeGB) * 1e9); q.ageDays = ageDays
        return q
    }

    /// Full-scope leaf categories for the always-visible legend; never page-limited.
    func legendQuery() -> FileQuery {
        var q = sceneQuery()
        q.parentID = nil
        q.leafResults = true
        q.knownSizesOnly = false
        q.subtreePath = subtreeScope()
        return q
    }
}
