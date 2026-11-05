import Foundation

/// Which quick-select level first reaches each path, for colouring the map by cleanup
/// safety. Derived only from the curated `AutoSelectionSpec` rules — never from age or
/// size — so the map and the level picker always agree.
public struct SafetyClassification: Sendable, Equatable {
    /// Selected path → lowest level selecting it (paths nest: a Junk item can sit inside
    /// a location taken whole at Caches).
    public let levels: [String: AutoSelectionLevel]
    /// The same paths sorted, for "contains reclaimable" prefix lookups.
    private let sorted: [String]

    public init(levels: [String: AutoSelectionLevel]) {
        self.levels = levels; sorted = levels.keys.sorted()
    }

    public init(results: [AutoSelectionLevel: AutoSelectionResult]) {
        var levels: [String: AutoSelectionLevel] = [:]
        for level in AutoSelectionLevel.allCases {
            for group in results[level]?.groups ?? [] {
                // A location whose every child is selected reads as selected itself.
                let paths = group.nodes.map(\.path) + (group.coversAllChildren ? [group.location.path] : [])
                for path in paths where levels[path] == nil { levels[path] = level }
            }
        }
        self.init(levels: levels)
    }

    public static let empty = SafetyClassification(levels: [:])

    /// The lowest level whose selection covers `path` (the path itself or an ancestor).
    public func level(of path: String) -> AutoSelectionLevel? {
        var best: AutoSelectionLevel?
        var candidate = Substring(path)
        while !candidate.isEmpty {
            if let level = levels[String(candidate)], best.map({ level < $0 }) ?? true { best = level }
            guard let slash = candidate.lastIndex(of: "/"), slash != candidate.startIndex else { break }
            candidate = candidate[..<slash]
        }
        return best
    }

    /// Whether something below `path` (but not `path` itself) is selectable at some level.
    public func containsSelectable(below path: String) -> Bool {
        let prefix = path + "/"
        var low = 0, high = sorted.count
        while low < high { let mid = (low + high) / 2; if sorted[mid] < prefix { low = mid + 1 } else { high = mid } }
        return low < sorted.count && sorted[low].hasPrefix(prefix)
    }
}

extension ScanIndex {
    /// One pass over every level's candidates, reduced to per-path safety levels.
    public func safetyClassification(home: String, unusedDays: Int, inspectPackages: Bool = false) -> SafetyClassification {
        SafetyClassification(results: autoSelectionResultsForAllLevels(home: home, unusedDays: unusedDays, inspectPackages: inspectPackages))
    }
}
