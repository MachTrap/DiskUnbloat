import Foundation
import CSQLite

/// Map-hiding ranges for queued deletion items. Entry paths hide their whole subtree;
/// a container whose every child is queued collapses to one descendants-only range, so a
/// bulk selection stays cheap without hiding the container folder itself — it survives
/// an "emptied but kept" cleanup and keeps its honest tile.
public struct HiddenRanges: Sendable, Equatable {
    public var paths: [String] = []
    public var subtrees: [String] = []
    public init() {}
    public init(paths: [String], subtrees: [String]) {
        self.paths = paths
        self.subtrees = subtrees
    }
    public var isEmpty: Bool { paths.isEmpty && subtrees.isEmpty }

    /// Drops paths already covered by another path's subtree. Sorted order visits a
    /// directory's descendants right after it, so one kept ancestor covers the whole run.
    public static func pruneSubsumed(_ paths: [String]) -> [String] {
        var kept: [String] = []
        var cover = ""
        for path in paths.sorted() where path != "/" {
            if !cover.isEmpty, path.isWithin(cover) { continue }
            kept.append(path)
            cover = path
        }
        return kept
    }
}

extension ScanIndex {
    /// Candidates for one quick-select level over the current index. The rules are
    /// path-based, so the "Dev tools" and "All caches" behavior falls out of the scan
    /// scope intersection instead of branching on the scan group.
    public func autoSelectionCandidates(
        home: String, level: AutoSelectionLevel, unusedDays: Int, inspectPackages: Bool = false
    ) -> AutoSelectionResult {
        autoSelectionResults(home: home, levels: [level], unusedDays: unusedDays, inspectPackages: inspectPackages)[level] ?? AutoSelectionResult(groups: [])
    }

    /// Normalized estimates for every level in one pass: each location's children are
    /// read once and evaluated per level.
    public func autoSelectionEstimates(home: String, unusedDays: Int, inspectPackages: Bool = false) -> [AutoSelectionLevel: AutoSelectionPreview] {
        autoSelectionResults(home: home, levels: AutoSelectionLevel.allCases, unusedDays: unusedDays, inspectPackages: inspectPackages)
            .mapValues(AutoSelectionPreview.init)
    }

    func autoSelectionResultsForAllLevels(home: String, unusedDays: Int, inspectPackages: Bool) -> [AutoSelectionLevel: AutoSelectionResult] {
        autoSelectionResults(home: home, levels: AutoSelectionLevel.allCases, unusedDays: unusedDays, inspectPackages: inspectPackages)
    }

    private func autoSelectionResults(
        home: String, levels: [AutoSelectionLevel], unusedDays: Int, inspectPackages: Bool
    ) -> [AutoSelectionLevel: AutoSelectionResult] {
        let cutoff = Date().addingTimeInterval(-Double(max(1, unusedDays)) * 86400)
        var groups: [AutoSelectionLevel: [AutoSelectionGroup]] = [:]
        var nameMatched: [FileNode]?
        for rule in AutoSelectionSpec.rules(home: home) {
            let active = levels.filter { rule.coverage(at: $0) != .none }
            guard !active.isEmpty else { continue }
            if let relative = rule.relativePath {
                let path = home + "/" + relative
                guard let location = node(path: path), location.isDirectory, !location.isSymbolicLink else { continue }
                switch rule.target {
                case .locationItself:
                    for level in active {
                        groups[level, default: []].append(AutoSelectionGroup(location: location, nodes: [location], coversAllChildren: false))
                    }
                case .children:
                    let children = childrenForSelection(of: location.id)
                    var total: Int?
                    for level in active {
                        let selected = AutoSelection.select(children: children, rule: rule, level: level, unusedBefore: cutoff)
                        guard !selected.isEmpty else { continue }
                        // Full coverage is claimed only against every indexed child, so an
                        // unselectable symlink or an unreadable entry keeps the exact
                        // per-child shape.
                        let count = total ?? allChildCount(of: location.id); total = count
                        groups[level, default: []].append(AutoSelectionGroup(
                            location: location, nodes: selected, coversAllChildren: selected.count == count,
                            exemptsSelection: rule.exemptsSelection))
                    }
                }
            } else {
                // Name-matched rebuildable folders anywhere in the scan.
                let folders = nameMatched ?? regenerableFolders(home: home, inspectPackages: inspectPackages)
                nameMatched = folders
                for level in active {
                    groups[level, default: []] += folders.map { AutoSelectionGroup(location: $0, nodes: [$0], coversAllChildren: false) }
                }
            }
        }
        var results: [AutoSelectionLevel: AutoSelectionResult] = [:]
        for level in levels { results[level] = AutoSelectionResult(groups: groups[level] ?? []) }
        return results
    }

    /// Every indexed direct child eligible for selection (complete, indexable rows).
    /// Symlinks and package internals stay out; `incomplete` rows cannot establish
    /// eligibility and are skipped wholesale.
    private func childrenForSelection(of parentID: Int64) -> [FileNode] {
        let columns = Self.rowColumns
        var result: [FileNode] = []
        var offset = 0
        while true {
            let page = readRows("SELECT \(columns) FROM nodes WHERE parent=\(parentID) AND incomplete=0 ORDER BY id LIMIT 512 OFFSET \(offset)")
            result += page
            if page.count < 512 { return result }
            offset += 512
        }
    }

    /// All indexed direct children, including ineligible ones, for honest full-coverage
    /// claims and hidden-range collapses.
    private func allChildCount(of parentID: Int64) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM nodes WHERE parent=\(parentID)", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// The regenerable-name candidates, matching the existing suggestion semantics
    /// (directories named node_modules, Pods, .build, … outside protected trees).
    private func regenerableFolders(home: String, inspectPackages: Bool) -> [FileNode] {
        var q = FileQuery()
        q.cleanupRule = .regenerable
        q.userHome = home
        q.inspectPackages = inspectPackages
        var result: [FileNode] = []
        var offset = 0
        while true {
            q.offset = offset
            let page = query(q)
            result += page
            if page.count < q.limit { return result }
            offset += page.count
        }
    }

    /// Exact map-hiding ranges for queued deletion items: subsumed entries are dropped,
    /// and a container whose every indexed child is queued collapses to one
    /// descendants-only range. Bulk selections therefore cost a handful of SQL terms
    /// instead of three per entry.
    public func coalescedHiddenRanges(for paths: [String]) -> HiddenRanges {
        var ranges = HiddenRanges()
        // Sorted order visits a directory's descendants right after it, so one kept
        // ancestor subsumes every path that follows inside its range.
        let kept = HiddenRanges.pruneSubsumed(paths)
        var byParent: [String: [String]] = [:]
        for path in kept {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            byParent[parent, default: []].append(path)
        }
        var collapsedChildren: Set<String> = []
        var collapsedParents: [String] = []
        for (parent, children) in byParent {
            guard children.count > 1, let container = node(path: parent),
                  allChildCount(of: container.id) == children.count else { continue }
            collapsedChildren.formUnion(children)
            collapsedParents.append(parent)
        }
        ranges.paths = kept.filter { !collapsedChildren.contains($0) }
        ranges.subtrees = collapsedParents.sorted()
        return ranges
    }
}
