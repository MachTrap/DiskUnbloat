import Foundation
import DiskCore

/// Everything that affects the browser summary, rows, legend, and statistics for one state.
/// Deliberately excludes the running-application cache exclusions, so candidate/suggestion
/// results (which depend on them) are never cached.
struct ResultsKey: Hashable {
    let revision: UInt64
    let currentID: Int64
    let metric: SizeMetric
    let inspectPackages: Bool
    let drawerTab: AnalysisTab
    let scope: ExplorerScope
    let search: String
    let minimumGB: Double
    let olderDays: Int
    let extensionFilter: String
    let hiddenPaths: [String]
    let sortName: Bool
    let ascending: Bool
}
struct CachedResults {
    let summary: SizeSummary
    let rows: [FileNode]
    let legend: [FileCategory]
    let statistics: [CategorySummary]
}

/// Builds the browser, statistics, and map queries for one explorer state so query
/// construction lives apart from the view model's orchestration. Candidate exclusions are
/// supplied pre-combined (running-application + session) because that lookup is main-actor work.
struct ExplorerQueries {
    let current: FileNode?
    let metric: SizeMetric
    let options: ScanOptions
    let drawerTab: AnalysisTab
    let scope: ExplorerScope
    let suggestion: Suggestion?
    let candidateRule: CleanupRule
    let hiddenPaths: [String]
    /// Running-application + session candidate exclusions; empty unless a candidate view is active.
    let excludedCandidatePaths: [String]
    let search: String
    let minimumGB: Double
    let olderDays: Int
    let extensionFilter: String
    let sortName: Bool
    let ascending: Bool
    let cacheRootPath: String?
    let homePath: String?
    let cacheAgeDays: Int
    let ageDays: Int
    let largeGB: Double
    let groupScan: Bool
    let pageSize: Int

    var hasFilters: Bool {
        !search.isEmpty || suggestion != nil || minimumGB > 0 || olderDays > 0 || !extensionFilter.isEmpty
    }

    func subtreeScope() -> String? {
        guard scope == .current, let current else { return nil }
        return groupScan && current.isGroupRoot ? nil : current.path
    }

    func browserQuery() -> FileQuery {
        var q = FileQuery()
        q.inspectPackages = options.inspectPackages; q.metric = metric
        if hasFilters || drawerTab != .files {
            q.leafResults = true
            if scope == .current { q.subtreePath = subtreeScope() }
        } else { q.parentID = current?.id }
        if drawerTab == .candidates || suggestion != nil {
            q.cleanupRule = drawerTab == .candidates ? candidateRule : suggestion?.rule
            q.userHome = homePath; q.cacheAgeDays = cacheAgeDays
            q.excludedCandidatePaths = excludedCandidatePaths
        }
        q.hiddenPaths = hiddenPaths
        q.search = search; q.minimumSize = Int64(max(0, minimumGB) * 1e9)
        q.olderThan = olderDays > 0 ? Date().addingTimeInterval(-Double(olderDays) * 86400) : nil
        q.fileExtension = extensionFilter; q.suggestion = nil; q.cacheRootPath = cacheRootPath
        q.largeThreshold = Int64(max(0.001, largeGB) * 1e9); q.ageDays = ageDays
        q.sortByName = drawerTab == .largest ? false : sortName; q.ascending = drawerTab == .largest ? false : ascending
        q.knownSizesOnly = drawerTab == .largest; q.limit = pageSize
        return q
    }

    /// Full-scope leaf statistics for the legend/Types tab; drawer pagination must not affect them.
    func statsQuery(from browser: FileQuery) -> FileQuery {
        var q = browser
        q.parentID = nil; q.leafResults = true; q.knownSizesOnly = false
        q.cleanupRule = suggestion?.rule; q.subtreePath = subtreeScope()
        return q
    }

    /// Map geometry must not change with drawer mode: resets drawer-only scoping to the folder view.
    func mapQuery(from browser: FileQuery) -> FileQuery {
        var q = browser
        q.cleanupRule = suggestion?.rule; q.knownSizesOnly = false
        q.parentID = hasFilters ? nil : current?.id; q.leafResults = hasFilters
        q.subtreePath = hasFilters ? subtreeScope() : nil
        return q
    }
}
