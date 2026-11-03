import Foundation

public struct FileQuery: Sendable {
    public var cleanupRule: CleanupRule?
    public var userHome: String?
    public var cacheAgeDays = 30
    public var excludedCandidatePaths: [String] = []
    /// Queued deletion items hidden from the map, browser, and statistics.
    public var hiddenPaths: [String] = []
    /// Containers whose every child is queued: their descendants hide with them, but the
    /// container folder itself stays visible (it survives an emptied cleanup).
    public var hiddenSubtrees: [String] = []
    public var metric: SizeMetric = .allocated
    public var knownSizesOnly = false
    public var leafResults = false
    public var inspectPackages = false
    public var subtreePath: String? = nil
    public var offset = 0
    public var parentID: Int64? = nil
    public var search = ""
    public var minimumSize: Int64 = 0
    public var olderThan: Date? = nil
    public var fileExtension = ""
    public var cacheRootPath: String? = nil
    public var suggestion: Suggestion? = nil
    public var largeThreshold: Int64 = 1_000_000_000
    public var ageDays = 180
    public var ascending = false
    public var sortByName = false
    public var limit = 2000
    public var hasPathExclusions: Bool {
        !hiddenPaths.isEmpty || !hiddenSubtrees.isEmpty || !excludedCandidatePaths.isEmpty
    }
    public init() {}
}
