import Foundation
import CSQLite

extension ScanIndex {
    public func node(_ id: Int64) -> FileNode? { read("SELECT * FROM nodes WHERE id=\(id)").first }
    private func predicate(_ q: FileQuery) -> (String, [String]) {
        var p = SQLPredicate()
        p.add("1=1")
        applyScope(q, to: &p)
        applyFilters(q, to: &p)
        if let suggestion = q.suggestion { applySuggestion(suggestion, q, to: &p) }
        if let rule = q.cleanupRule { applyCleanupRule(rule, q, to: &p) }
        for path in q.hiddenPaths { applyPathExclusion(path, to: &p) }
        return (p.sql, p.strings)
    }

    /// Accumulates SQL WHERE clauses and their ordered string bindings; the `?` in the joined
    /// SQL map positionally onto `strings`, so each clause appends its own binds with it.
    private struct SQLPredicate {
        var clauses: [String] = []
        var strings: [String] = []
        mutating func add(_ clause: String) { clauses.append(clause) }
        mutating func add(_ clause: String, bind: [String]) { clauses.append(clause); strings += bind }
        var sql: String { clauses.joined(separator: " AND ") }
    }

    private func applyScope(_ q: FileQuery, to p: inout SQLPredicate) {
        if q.knownSizesOnly { p.add(q.metric == .allocated ? "allocated IS NOT NULL" : "logical IS NOT NULL") }
        if !q.inspectPackages { p.add("insidePackage=0") }
        if q.leafResults && q.cleanupRule?.isCache != true { p.add(q.inspectPackages ? "directory=0" : "(directory=0 OR package=1)") }
        p.add("parent IS NOT NULL")
        if let path = q.subtreePath { p.add("path>=? COLLATE BINARY AND path<? COLLATE BINARY", bind: [path.pathRange.lower, path.pathRange.upper]) }
        if let id = q.parentID { p.add("parent=\(id)") }
    }

    private func applyFilters(_ q: FileQuery, to p: inout SQLPredicate) {
        if !q.search.isEmpty { p.add("instr(searchName,?)>0", bind: [folded(q.search)]) }
        if q.minimumSize > 0 { p.add("\(q.metric == .allocated ? "knownAllocated" : "knownLogical")>=\(q.minimumSize)") }
        if let date = q.olderThan { p.add("modified<\(date.timeIntervalSince1970)") }
        if !q.fileExtension.isEmpty { p.add("lower(path) LIKE ? ESCAPE '\\'", bind: ["%." + escapeLike(q.fileExtension.lowercased())]) }
    }

    private func applySuggestion(_ suggestion: Suggestion, _ q: FileQuery, to p: inout SQLPredicate) {
        // Regenerable and cache candidates are folders; the other suggestions are leaf entries.
        p.add(suggestion == .regenerable || suggestion == .caches ? "insidePackage=0 AND symlink=0" : "directory=0 AND insidePackage=0 AND symlink=0")
        let cutoff = Date().addingTimeInterval(-Double(max(1, q.ageDays)) * 86400).timeIntervalSince1970
        switch suggestion {
        case .large: p.add("allocated>=\(q.largeThreshold)")
        case .downloads: p.add("path LIKE '%/Downloads/%' AND modified<\(cutoff)")
        case .archives: p.add("modified<\(cutoff) AND (lower(name) LIKE '%.zip' OR lower(name) LIKE '%.dmg' OR lower(name) LIKE '%.pkg' OR lower(name) LIKE '%.tar' OR lower(name) LIKE '%.gz')")
        case .regenerable:
            var binds: [String] = []; let clause = regenerableNameSQL(&binds)
            p.add("directory=1 AND " + clause, bind: binds)
        case .caches:
            // All curated cache locations, not only ~/Library/Caches.
            if let home = q.userHome {
                var binds: [String] = []
                let parts = CleanupRule.userCaches.roots(relativeTo: home).map { root -> String in
                    if root.candidate == .rootItself { binds.append(root.path); return "path=?" }
                    let range = root.path.pathRange; binds += [range.lower, range.upper]
                    return "path>=? COLLATE BINARY AND path<? COLLATE BINARY"
                }
                p.add("(" + parts.joined(separator: " OR ") + ")", bind: binds)
            } else if let root = q.cacheRootPath {
                p.add("path>=? COLLATE BINARY AND path<? COLLATE BINARY", bind: [root.pathRange.lower, root.pathRange.upper])
            } else { p.add("path LIKE '/Users/%/Library/Caches/%'") }
        }
    }

    private func applyCleanupRule(_ rule: CleanupRule, _ q: FileQuery, to p: inout SQLPredicate) {
        p.add("symlink=0 AND insidePackage=0 AND incomplete=0")
        if !rule.isCache && rule != .regenerable { p.add(q.inspectPackages ? "directory=0" : "(directory=0 OR package=1)") }
        if rule == .large {
            p.add("allocated>=\(q.largeThreshold)")
        } else if rule == .regenerable {
            // Regenerable folders are identified by name anywhere in the scanned tree.
            var binds: [String] = []; let clause = regenerableNameSQL(&binds)
            p.add("directory=1 AND " + clause, bind: binds)
        } else {
            let roots = q.userHome.flatMap { rule.roots(relativeTo: $0) } ?? []
            if roots.isEmpty {
                if rule.isCache || rule == .downloads { p.add("0=1") }
                if rule == .archives {
                    let cutoff = Date().addingTimeInterval(-Double(max(1, q.ageDays)) * 86400).timeIntervalSince1970
                    p.add("category='Archives' AND unknownModified=0 AND latestModified<\(cutoff) AND unknownAllocated=0")
                }
            } else {
                // Age gating applies per root so version-staleness roots can keep the newest entry.
                var binds: [String] = []
                let rootClauses = roots.map { root -> String in
                    var parts: [String] = []
                    if root.candidate == .rootItself {
                        parts.append("path=?"); binds.append(root.path)
                        if rule.isCache || rule == .downloads {
                            let days = rule.isCache ? q.cacheAgeDays : q.ageDays
                            let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970
                            parts.append("unknownModified=0 AND latestModified<\(cutoff) AND unknownAllocated=0")
                        }
                    } else {
                        parts.append("path>=? COLLATE BINARY AND path<? COLLATE BINARY")
                        let range = root.path.pathRange; binds += [range.lower, range.upper]
                        if root.candidate == .childrenKeepingNewest {
                            // Exclude the subtree of the most recently used direct child.
                            parts.append("NOT(path>=(SELECT ?||'/'||name FROM nodes WHERE parent=(SELECT id FROM nodes WHERE path=?) ORDER BY COALESCE(latestModified,0) DESC,name DESC LIMIT 1) AND path<(SELECT ?||'/'||name FROM nodes WHERE parent=(SELECT id FROM nodes WHERE path=?) ORDER BY COALESCE(latestModified,0) DESC,name DESC LIMIT 1)||'0')")
                            binds += [root.path, root.path, root.path, root.path]
                        } else if rule.isCache || rule == .downloads {
                            let days = rule.isCache ? q.cacheAgeDays : q.ageDays
                            let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970
                            parts.append("unknownModified=0 AND latestModified<\(cutoff) AND unknownAllocated=0")
                        }
                        if rule.isCache {
                            // Direct cache-root children are disjoint; narrower scans fall back to leaf entries.
                            parts.append("(parent=(SELECT id FROM nodes WHERE path=?) OR (NOT EXISTS(SELECT 1 FROM nodes WHERE path=?) AND directory=0))")
                            binds += [root.path, root.path]
                        }
                    }
                    return "(" + parts.joined(separator: " AND ") + ")"
                }
                p.add("(" + rootClauses.joined(separator: " OR ") + ")", bind: binds)
            }
        }
        for path in q.excludedCandidatePaths { applyPathExclusion(path, to: &p) }
        applySystemExclusions(rule, q, to: &p)
    }

    private func applySystemExclusions(_ rule: CleanupRule, _ q: FileQuery, to p: inout SQLPredicate) {
        // Curated roots may legitimately live under managed-application trees; those blanket
        // exclusions are dropped only when a declared root requires it.
        let roots = q.userHome.flatMap { rule.roots(relativeTo: $0) } ?? []
        var generic = ["path NOT LIKE '/usr/%'", "path NOT LIKE '/bin/%'", "path NOT LIKE '/sbin/%'", "path NOT LIKE '/dev/%'", "path NOT LIKE '/etc/%'", "path NOT LIKE '/var/%'", "path NOT LIKE '/System/%'", "path NOT LIKE '/Library/%'", "path NOT LIKE '/Applications/%'", "path NOT LIKE '/private/%'", "path NOT LIKE '%/Library/Containers/%'", "path NOT LIKE '%/Library/Group Containers/%'", "path NOT LIKE '%/Library/Application Support/%'"]
        if roots.contains(where: { $0.path.contains("/Library/Group Containers/") }) { generic.removeAll { $0.contains("Group Containers") } }
        if roots.contains(where: { $0.path.contains("/Library/Application Support/") }) { generic.removeAll { $0.contains("Application Support") } }
        for clause in generic { p.add(clause) }
    }

    private func applyPathExclusion(_ path: String, to p: inout SQLPredicate) {
        let range = path.pathRange
        p.add("NOT(path=? OR (path>=? COLLATE BINARY AND path<? COLLATE BINARY))", bind: [path, range.lower, range.upper])
    }
    public func query(_ q: FileQuery) -> [FileNode] {
        let (whereSQL, strings) = predicate(q)
        let order = q.sortByName ? "name COLLATE NOCASE" : q.metric == .allocated ? "knownAllocated" : "knownLogical"
        return readRows("SELECT id,parent,path,name,directory,package,symlink,logical,allocated,modified,identity,fingerprint,insidePackage,knownLogical,knownAllocated,unknownLogical,unknownAllocated,latestModified,unknownModified FROM nodes WHERE \(whereSQL) ORDER BY \(order) \(q.ascending ? "ASC" : "DESC"),id LIMIT \(max(1, min(q.limit, 10000))) OFFSET \(max(0, q.offset))", strings: strings)
    }
    public func summary(_ q: FileQuery) -> SizeSummary {
        let (whereSQL, strings) = predicate(q)
        let known = q.metric == .allocated ? "knownAllocated" : "knownLogical"
        let unknown = q.metric == .allocated ? "unknownAllocated" : "unknownLogical"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(\(known)),0),COUNT(*),COALESCE(SUM(\(unknown)),0) FROM nodes WHERE \(whereSQL)", -1, &stmt, nil) == SQLITE_OK else { return SizeSummary() }
        defer { sqlite3_finalize(stmt) }
        for (i,value) in strings.enumerated() { bind(value, to: Int32(i+1), stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return SizeSummary() }
        return SizeSummary(knownBytes: sqlite3_column_int64(stmt,0), itemCount: Int(sqlite3_column_int64(stmt,1)), unknownCount: Int(sqlite3_column_int64(stmt,2)))
    }
    public func node(path: String) -> FileNode? { read("SELECT * FROM nodes WHERE path=?", strings: [path]).first }
    public func categorySummaries(_ query: FileQuery) -> [CategorySummary] {
        var q = query; q.leafResults = true; q.parentID = nil
        let (predicate, strings) = predicate(q)
        let known = q.metric == .allocated ? "knownAllocated" : "knownLogical"
        let unknown = q.metric == .allocated ? "unknownAllocated" : "unknownLogical"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT category,SUM(\(known)),COUNT(*),SUM(\(unknown)) FROM nodes WHERE \(predicate) GROUP BY category", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i,value) in strings.enumerated() { bind(value, to: Int32(i+1), stmt) }
        var result: [CategorySummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(CategorySummary(category: FileCategory(rawValue: string(stmt,0)) ?? .other, bytes: sqlite3_column_int64(stmt,1), count: Int(sqlite3_column_int64(stmt,2)), unknown: Int(sqlite3_column_int64(stmt,3))))
        }
        // Unread ordinary folders have no leaf row; expose zero-byte unknown markers separately.
        var markerQuery = q; markerQuery.leafResults = false
        let (markerPredicate, markerStrings) = self.predicate(markerQuery)
        var marker: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM nodes WHERE \(markerPredicate) AND directory=1 AND package=0 AND incomplete=1", -1, &marker, nil) == SQLITE_OK {
            for (i,value) in markerStrings.enumerated() { bind(value, to: Int32(i+1), marker) }
            if sqlite3_step(marker) == SQLITE_ROW {
                let count = Int(sqlite3_column_int64(marker,0))
                if count > 0 {
                    if let i = result.firstIndex(where: { $0.category == .other }) {
                        let previous = result[i]
                        result[i] = CategorySummary(category: .other,bytes: previous.bytes,count: previous.count+count,unknown: previous.unknown+count)
                    } else { result.append(CategorySummary(category: .other,bytes: 0,count: count,unknown: count)) }
                }
            }
        }
        sqlite3_finalize(marker)
        return result.sorted { $0.bytes > $1.bytes }
    }
    /// Distinct file categories present in the query scope. Lighter than the full
    /// `categorySummaries` aggregation; used by the always-visible legend.
    public func categoryList(_ query: FileQuery) -> [FileCategory] {
        var q = query; q.leafResults = true; q.parentID = nil
        let (predicate, strings) = predicate(q)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT category FROM nodes WHERE \(predicate)", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in strings.enumerated() { bind(value, to: Int32(i + 1), stmt) }
        var result: [FileCategory] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let category = FileCategory(rawValue: string(stmt, 0)) { result.append(category) }
        }
        return result
    }
    /// Shared name match for regenerable folders, used by both the rule and its suggestion.
    private func regenerableNameSQL(_ strings: inout [String]) -> String {
        let names = CleanupRule.regenerableNames
        let exact = names.map { _ in "name=?" }.joined(separator: " OR ")
        let prefixes = CleanupRule.regenerableNamePrefixes
        let like = prefixes.map { _ in "name LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
        strings += names + prefixes.map { escapeLike($0) + "%" }
        return "(\(exact)\(prefixes.isEmpty ? "" : " OR \(like)"))"
    }
}

/// A consistent snapshot of every result the explorer shows for one state, produced in a
/// single actor call so the browser summary, rows, legend, statistics, and map all reflect
/// the same index revision.
public struct ExplorerSnapshot: Sendable {
    public let revision: UInt64
    public let summary: SizeSummary
    public let rows: [FileNode]
    public let legendCategories: [FileCategory]
    public let statistics: [CategorySummary]
    public let scene: MapScene
    public init(revision: UInt64, summary: SizeSummary, rows: [FileNode], legendCategories: [FileCategory], statistics: [CategorySummary], scene: MapScene) {
        self.revision = revision; self.summary = summary; self.rows = rows
        self.legendCategories = legendCategories; self.statistics = statistics; self.scene = scene
    }
}

extension ScanIndex {
    /// Compute the browser summary, page rows, legend categories, optional full category
    /// statistics, and an optional map scene in one atomic actor turn. `includeScene` and
    /// `includeStatistics` let callers skip work they already have cached.
    public func explorerSnapshot(browser: FileQuery, stats: FileQuery, mapQuery: FileQuery, mapRootID: Int64, filtered: Bool, includeStatistics: Bool, includeScene: Bool) -> ExplorerSnapshot {
        ExplorerSnapshot(
            revision: revision,
            summary: summary(browser),
            rows: query(browser),
            legendCategories: categoryList(stats),
            statistics: includeStatistics ? categorySummaries(stats) : [],
            scene: includeScene ? mapScene(rootID: mapRootID, query: mapQuery, filtered: filtered) : MapScene(rootID: mapRootID)
        )
    }
}
