import Foundation
import CSQLite

/// Per-row values derived from a node's name and path. Scan workers compute them in
/// parallel so the index actor only binds and steps.
struct DerivedColumns: Sendable {
    let searchName: String
    let category: String
    init(_ node: FileNode) { searchName = ScanIndex.fold(node.name); category = node.category.rawValue }
}

extension ScanIndex {
    public func insert(_ nodes: [FileNode]) throws { try insert(nodes, derived: nil) }
    /// `derived`, when given, must be aligned with `nodes`.
    func insert(_ nodes: [FileNode], derived: [DerivedColumns]?) throws {
        try exec("BEGIN TRANSACTION")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO nodes(id,parent,path,name,directory,package,symlink,logical,allocated,modified,identity,insidePackage,fingerprint,searchName,knownLogical,knownAllocated,unknownLogical,unknownAllocated,category,rawLogical,rawAllocated,latestModified,unknownModified,summary,summaryModified) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw IndexError.database }
            defer { sqlite3_finalize(stmt) }
            for (i, n) in nodes.enumerated() {
                bindRow(n, derived: derived?[i] ?? DerivedColumns(n), to: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw IndexError.database }
            }
            try exec("UPDATE metadata SET highWater=MAX(highWater,(SELECT COALESCE(MAX(id),0) FROM nodes))")
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    /// Reset the prepared statement and bind one node's columns (leaves NULL for nil fields).
    private func bindRow(_ n: FileNode, derived: DerivedColumns, to stmt: OpaquePointer?) {
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        sqlite3_bind_int64(stmt, 1, n.id)
        if let p = n.parentID { sqlite3_bind_int64(stmt, 2, p) }
        bind(n.path, to: 3, stmt); bind(n.name, to: 4, stmt)
        sqlite3_bind_int(stmt, 5, n.isDirectory ? 1 : 0); sqlite3_bind_int(stmt, 6, n.isPackage ? 1 : 0); sqlite3_bind_int(stmt, 7, n.isSymbolicLink ? 1 : 0)
        if let s = n.logicalSize { sqlite3_bind_int64(stmt, 8, s) }
        if let s = n.allocatedSize { sqlite3_bind_int64(stmt, 9, s) }
        if let d = n.modified { sqlite3_bind_double(stmt, 10, d.timeIntervalSince1970) }
        bind(n.identity, to: 11, stmt); sqlite3_bind_int(stmt, 12, n.packageAncestor ? 1 : 0)
        if let fingerprint = n.fingerprint { bind(fingerprint, to: 13, stmt) }
        bind(derived.searchName, to: 14, stmt)
        sqlite3_bind_int64(stmt, 15, n.knownLogicalSize); sqlite3_bind_int64(stmt, 16, n.knownAllocatedSize)
        sqlite3_bind_int64(stmt, 17, Int64(n.unknownLogicalCount)); sqlite3_bind_int64(stmt, 18, Int64(n.unknownAllocatedCount))
        bind(derived.category, to: 19, stmt)
        if let s = n.logicalSize { sqlite3_bind_int64(stmt, 20, s) }
        if let s = n.allocatedSize { sqlite3_bind_int64(stmt, 21, s) }
        if let d = n.modified { sqlite3_bind_double(stmt, 22, d.timeIntervalSince1970) }
        sqlite3_bind_int(stmt, 23, n.modified == nil ? 1 : 0)
        sqlite3_bind_int(stmt, 24, n.isSummarized ? 1 : 0)
        if n.isSummarized, let d = n.latestContentModification { sqlite3_bind_double(stmt, 25, d.timeIntervalSince1970) }
    }
    public func issue(path: String, message: String) {
        var s: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT INTO issues VALUES(?,?)", -1, &s, nil)
        defer { sqlite3_finalize(s) }; bind(path, to: 1, s); bind(message, to: 2, s); sqlite3_step(s)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if bulkLoading {
            // Without path_index each mark would scan the whole table; collect the paths
            // and apply them in one pass before aggregation.
            var pending: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO pending_marks VALUES(?),(?)", -1, &pending, nil)
            defer { sqlite3_finalize(pending) }; bind(path, to: 1, pending); bind(parent, to: 2, pending); sqlite3_step(pending)
            return
        }
        var mark: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE nodes SET incomplete=1 WHERE path=? OR path=? OR parent IS NULL", -1, &mark, nil)
        defer { sqlite3_finalize(mark) }; bind(path, to: 1, mark); bind(parent, to: 2, mark); sqlite3_step(mark)
    }
    public func issues() -> [ScanIssue] {
        var s: OpaquePointer?; sqlite3_prepare_v2(db, "SELECT path,message FROM issues LIMIT 500", -1, &s, nil)
        defer { sqlite3_finalize(s) }; var result: [ScanIssue] = []
        while sqlite3_step(s) == SQLITE_ROW { result.append(ScanIssue(path: string(s,0),message: string(s,1))) }; return result
    }
    /// Prepares a fresh index for a scan's inserts: secondary indexes are dropped and
    /// issue marks deferred until `aggregate()` (or `endBulkLoad()`) rebuilds them.
    /// Only an empty index switches; one that already holds rows keeps its indexes.
    public func beginBulkLoad() throws {
        guard !bulkLoading else { return }
        var probe: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT EXISTS(SELECT 1 FROM nodes)", -1, &probe, nil) == SQLITE_OK else { throw IndexError.database }
        let populated = sqlite3_step(probe) == SQLITE_ROW && sqlite3_column_int(probe, 0) != 0
        sqlite3_finalize(probe)
        guard !populated else { return }
        try exec(Self.secondaryIndexNames.map { "DROP INDEX IF EXISTS \($0);" }.joined() + "CREATE TEMP TABLE IF NOT EXISTS pending_marks(path TEXT PRIMARY KEY);")
        bulkLoading = true
    }
    /// Leaves bulk-load mode without aggregating (a failed scan): applies deferred marks and
    /// restores every index so later queries keep their plans. Idempotent.
    public func endBulkLoad() throws {
        guard bulkLoading else { return }
        try applyPendingMarks()
        try exec(Self.secondaryIndexes)
        bulkLoading = false
    }
    private func applyPendingMarks() throws {
        try exec("""
        UPDATE nodes SET incomplete=1 WHERE path IN (SELECT path FROM pending_marks) OR (parent IS NULL AND EXISTS(SELECT 1 FROM pending_marks));
        DROP TABLE pending_marks;
        """)
    }
    public func aggregate() throws {
        try exec("BEGIN TRANSACTION")
        do {
            let loading = bulkLoading
            if loading { try applyPendingMarks() }
            try aggregateInMemory()
            // Indexes are built after the directory updates so those never maintain them.
            if loading { try exec(Self.secondaryIndexes); bulkLoading = false }
            try exec("COMMIT"); revision &+= 1
        }
        catch { try? exec("ROLLBACK"); throw error }
    }

    /// Full-table aggregation in one read and one bottom-up pass. Semantics match
    /// `aggregateInsideTransaction()` exactly (a test compares them row by row): leaves take
    /// their raw sizes, hard-link aliases after the lowest id count zero, summarized folders
    /// act as leaves, and every other folder sums its children — unknown when incomplete or
    /// when any child's size is unknown.
    func aggregateInMemory() throws {
        struct Row {
            var id: Int64; var parent: Int64?; var directory: Bool; var symlink: Bool; var summary: Bool; var incomplete: Bool
            var identity: String; var rawLogical: Int64?; var rawAllocated: Int64?; var modified: Double?; var summaryModified: Double?
            // Stored aggregate columns, compared so unchanged leaves are not rewritten.
            var logical: Int64?; var allocated: Int64?; var knownLogical: Int64; var knownAllocated: Int64
            var unknownLogical: Int64; var unknownAllocated: Int64; var latest: Double?; var unknownModified: Int64
        }
        struct Totals: Equatable {
            var logical: Int64?; var allocated: Int64?; var knownLogical: Int64 = 0; var knownAllocated: Int64 = 0
            var unknownLogical: Int64 = 0; var unknownAllocated: Int64 = 0; var latest: Double?; var unknownModified: Int64 = 0
        }
        struct Sums {
            var count = 0; var logicalCount = 0; var allocatedCount = 0; var logical: Int64 = 0; var allocated: Int64 = 0
            var knownLogical: Int64 = 0; var knownAllocated: Int64 = 0; var unknownLogical: Int64 = 0; var unknownAllocated: Int64 = 0
            var latest: Double?; var unknownModified: Int64 = 0
            mutating func add(_ t: Totals) {
                count += 1
                if let v = t.logical { logicalCount += 1; logical += v }
                if let v = t.allocated { allocatedCount += 1; allocated += v }
                knownLogical += t.knownLogical; knownAllocated += t.knownAllocated
                unknownLogical += t.unknownLogical; unknownAllocated += t.unknownAllocated
                if let v = t.latest { latest = max(latest ?? v, v) }
                unknownModified += t.unknownModified
            }
        }
        func optionalInt(_ s: OpaquePointer?, _ c: Int32) -> Int64? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_int64(s, c) }
        func optionalDouble(_ s: OpaquePointer?, _ c: Int32) -> Double? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_double(s, c) }

        var rows: [Row] = []
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,parent,directory,symlink,summary,incomplete,identity,rawLogical,rawAllocated,modified,summaryModified,logical,allocated,knownLogical,knownAllocated,unknownLogical,unknownAllocated,latestModified,unknownModified FROM nodes", -1, &select, nil) == SQLITE_OK else { throw IndexError.database }
        while sqlite3_step(select) == SQLITE_ROW {
            let s = select
            rows.append(Row(id: sqlite3_column_int64(s, 0), parent: optionalInt(s, 1), directory: sqlite3_column_int(s, 2) != 0, symlink: sqlite3_column_int(s, 3) != 0, summary: sqlite3_column_int(s, 4) != 0, incomplete: sqlite3_column_int(s, 5) != 0, identity: string(s, 6), rawLogical: optionalInt(s, 7), rawAllocated: optionalInt(s, 8), modified: optionalDouble(s, 9), summaryModified: optionalDouble(s, 10), logical: optionalInt(s, 11), allocated: optionalInt(s, 12), knownLogical: sqlite3_column_int64(s, 13), knownAllocated: sqlite3_column_int64(s, 14), unknownLogical: sqlite3_column_int64(s, 15), unknownAllocated: sqlite3_column_int64(s, 16), latest: optionalDouble(s, 17), unknownModified: sqlite3_column_int64(s, 18)))
        }
        sqlite3_finalize(select)

        var position: [Int64: Int] = [:]; position.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() { position[row.id] = i }
        // The lowest id of every hard-linked identity keeps the bytes.
        var canonical: [String: Int64] = [:]
        for row in rows where !row.directory && !row.symlink && !row.identity.isEmpty {
            if let existing = canonical[row.identity] { if row.id < existing { canonical[row.identity] = row.id } }
            else { canonical[row.identity] = row.id }
        }
        // Depth via parent links (memoized) orders folders children-first; path length
        // does not, because the synthetic group wrapper's path is not a filesystem path.
        var depth = [Int](repeating: -1, count: rows.count)
        var chain: [Int] = []
        for start in rows.indices where depth[start] < 0 {
            var cursor = start
            while depth[cursor] < 0, let parent = rows[cursor].parent, let up = position[parent], up != cursor { chain.append(cursor); cursor = up }
            var level = depth[cursor] < 0 ? 0 : depth[cursor]
            if depth[cursor] < 0 { depth[cursor] = 0 }
            while let next = chain.popLast() { level += 1; depth[next] = level }
        }

        var totals = [Totals](repeating: Totals(), count: rows.count)
        var sums: [Int: Sums] = [:]
        var leafUpdates: [Int] = []
        for (i, row) in rows.enumerated() where !row.directory {
            var t = Totals(logical: row.rawLogical, allocated: row.rawAllocated, knownLogical: row.rawLogical ?? 0, knownAllocated: row.rawAllocated ?? 0, unknownLogical: row.rawLogical == nil ? 1 : 0, unknownAllocated: row.rawAllocated == nil ? 1 : 0, latest: row.modified, unknownModified: row.modified == nil ? 1 : 0)
            if !row.symlink && !row.identity.isEmpty && canonical[row.identity] != row.id {
                t.logical = 0; t.allocated = 0; t.knownLogical = 0; t.knownAllocated = 0; t.unknownLogical = 0; t.unknownAllocated = 0
            }
            totals[i] = t
            let stored = Totals(logical: row.logical, allocated: row.allocated, knownLogical: row.knownLogical, knownAllocated: row.knownAllocated, unknownLogical: row.unknownLogical, unknownAllocated: row.unknownAllocated, latest: row.latest, unknownModified: row.unknownModified)
            if stored != t { leafUpdates.append(i) }
            if let parent = row.parent, let up = position[parent] { sums[up, default: Sums()].add(t) }
        }
        let folders = rows.indices.filter { rows[$0].directory }.sorted { depth[$0] > depth[$1] }
        for i in folders {
            let row = rows[i]; let incomplete: Int64 = row.incomplete ? 1 : 0
            var t = Totals()
            if row.summary {
                t = Totals(logical: row.incomplete ? nil : row.rawLogical, allocated: row.incomplete ? nil : row.rawAllocated, knownLogical: row.rawLogical ?? 0, knownAllocated: row.rawAllocated ?? 0, unknownLogical: max(incomplete, row.rawLogical == nil ? 1 : 0), unknownAllocated: max(incomplete, row.rawAllocated == nil ? 1 : 0), latest: max(row.modified ?? 0, row.summaryModified ?? 0), unknownModified: max(incomplete, row.modified == nil ? 1 : 0))
            } else {
                let s = sums[i] ?? Sums()
                t.logical = !row.incomplete && s.logicalCount == s.count ? s.logical : nil
                t.allocated = !row.incomplete && s.allocatedCount == s.count ? s.allocated : nil
                t.knownLogical = s.knownLogical; t.knownAllocated = s.knownAllocated
                t.unknownLogical = max(incomplete, s.unknownLogical); t.unknownAllocated = max(incomplete, s.unknownAllocated)
                t.latest = max(row.modified ?? 0, s.latest ?? 0)
                t.unknownModified = max(incomplete, row.modified == nil ? 1 : 0, s.unknownModified)
            }
            totals[i] = t
            if let parent = row.parent, let up = position[parent] { sums[up, default: Sums()].add(t) }
        }

        var update: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE nodes SET logical=?,allocated=?,knownLogical=?,knownAllocated=?,unknownLogical=?,unknownAllocated=?,latestModified=?,unknownModified=? WHERE id=?", -1, &update, nil) == SQLITE_OK else { throw IndexError.database }
        defer { sqlite3_finalize(update) }
        for i in leafUpdates + folders {
            let t = totals[i]
            sqlite3_reset(update); sqlite3_clear_bindings(update)
            if let v = t.logical { sqlite3_bind_int64(update, 1, v) }
            if let v = t.allocated { sqlite3_bind_int64(update, 2, v) }
            sqlite3_bind_int64(update, 3, t.knownLogical); sqlite3_bind_int64(update, 4, t.knownAllocated)
            sqlite3_bind_int64(update, 5, t.unknownLogical); sqlite3_bind_int64(update, 6, t.unknownAllocated)
            if let v = t.latest { sqlite3_bind_double(update, 7, v) }
            sqlite3_bind_int64(update, 8, t.unknownModified)
            sqlite3_bind_int64(update, 9, rows[i].id)
            guard sqlite3_step(update) == SQLITE_DONE else { throw IndexError.database }
        }
    }
    func aggregateInsideTransaction(affectedOnly: Bool = false) throws {
        let leafScope = affectedOnly ? " AND identity IN (SELECT identity FROM refresh_affected)" : ""
        let directoryScope = affectedOnly ? " AND id IN (SELECT id FROM refresh_directories)" : ""
        // Reassign counted bytes from raw metadata across the entire indexed scope.
        try exec("""
        UPDATE nodes SET logical=rawLogical,allocated=rawAllocated,knownLogical=COALESCE(rawLogical,0),knownAllocated=COALESCE(rawAllocated,0),unknownLogical=rawLogical IS NULL,unknownAllocated=rawAllocated IS NULL,latestModified=modified,unknownModified=modified IS NULL WHERE directory=0\(leafScope);
        UPDATE nodes SET logical=0,allocated=0,knownLogical=0,knownAllocated=0,unknownLogical=0,unknownAllocated=0 WHERE directory=0 AND symlink=0 AND identity<>'' AND id<>(SELECT MIN(alias.id) FROM nodes alias WHERE alias.identity=nodes.identity AND alias.directory=0 AND alias.symlink=0)\(leafScope);
        """)
        // Summarized folders have no indexed children: their measured totals act like a
        // leaf's raw sizes, and an unreadable part keeps the exact size unknown.
        try exec("""
        UPDATE nodes SET logical=CASE WHEN incomplete=0 THEN rawLogical END,allocated=CASE WHEN incomplete=0 THEN rawAllocated END,knownLogical=COALESCE(rawLogical,0),knownAllocated=COALESCE(rawAllocated,0),unknownLogical=MAX(incomplete,rawLogical IS NULL),unknownAllocated=MAX(incomplete,rawAllocated IS NULL),latestModified=MAX(COALESCE(modified,0),COALESCE(summaryModified,0)),unknownModified=MAX(incomplete,modified IS NULL) WHERE directory=1 AND summary=1\(directoryScope);
        """)
        // Path depth remains valid when stable IDs survive subtree replacements.
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM nodes WHERE directory=1 AND summary=0\(directoryScope) ORDER BY CASE WHEN path='\(ScanGroup.path)' THEN -1 ELSE length(path) END DESC", -1, &s, nil) == SQLITE_OK else { throw IndexError.database }
        defer { sqlite3_finalize(s) }
        do {
            var update: OpaquePointer?
            sqlite3_prepare_v2(db, """
            UPDATE nodes AS target SET
              latestModified=MAX(COALESCE(modified,0),(SELECT COALESCE(MAX(latestModified),0) FROM nodes WHERE parent=?1)),
              unknownModified=MAX(incomplete,modified IS NULL,(SELECT COALESCE(SUM(unknownModified),0) FROM nodes WHERE parent=?1)),
              logical=(SELECT CASE WHEN target.incomplete=0 AND COUNT(*)=COUNT(logical) THEN COALESCE(SUM(logical),0) END FROM nodes WHERE parent=?1),
              allocated=(SELECT CASE WHEN target.incomplete=0 AND COUNT(*)=COUNT(allocated) THEN COALESCE(SUM(allocated),0) END FROM nodes WHERE parent=?1),
              knownLogical=(SELECT COALESCE(SUM(knownLogical),0) FROM nodes WHERE parent=?1),
              knownAllocated=(SELECT COALESCE(SUM(knownAllocated),0) FROM nodes WHERE parent=?1),
              unknownLogical=MAX(incomplete,(SELECT COALESCE(SUM(unknownLogical),0) FROM nodes WHERE parent=?1)),
              unknownAllocated=MAX(incomplete,(SELECT COALESCE(SUM(unknownAllocated),0) FROM nodes WHERE parent=?1)) WHERE id=?1
            """, -1, &update, nil)
            defer { sqlite3_finalize(update) }
            while sqlite3_step(s) == SQLITE_ROW {
                let id = sqlite3_column_int64(s, 0); sqlite3_reset(update)
                sqlite3_bind_int64(update, 1, id)
                guard sqlite3_step(update) == SQLITE_DONE else { throw IndexError.database }
            }
        } catch { throw error }
    }
    public func remove(paths: [String]) throws {
        for path in paths {
            var s: OpaquePointer?; sqlite3_prepare_v2(db, "DELETE FROM nodes WHERE path=? OR path LIKE ? ESCAPE '\\'", -1, &s, nil)
            bind(path, to: 1, s); bind(escapeLike(path) + "/%", to: 2, s)
            guard sqlite3_step(s) == SQLITE_DONE else { sqlite3_finalize(s); throw IndexError.database }; sqlite3_finalize(s)
        }
        try aggregate()
    }
}
