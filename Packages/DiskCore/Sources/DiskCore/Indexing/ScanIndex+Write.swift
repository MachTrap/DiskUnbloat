import Foundation
import CSQLite

extension ScanIndex {
    public func insert(_ nodes: [FileNode]) throws {
        try exec("BEGIN TRANSACTION")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO nodes(id,parent,path,name,directory,package,symlink,logical,allocated,modified,identity,insidePackage,fingerprint,searchName,knownLogical,knownAllocated,unknownLogical,unknownAllocated,category,rawLogical,rawAllocated,latestModified,unknownModified) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw IndexError.database }
            defer { sqlite3_finalize(stmt) }
            for n in nodes {
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
                bind(folded(n.name), to: 14, stmt)
                sqlite3_bind_int64(stmt, 15, n.knownLogicalSize); sqlite3_bind_int64(stmt, 16, n.knownAllocatedSize)
                sqlite3_bind_int64(stmt, 17, Int64(n.unknownLogicalCount)); sqlite3_bind_int64(stmt, 18, Int64(n.unknownAllocatedCount))
                bind(n.category.rawValue, to: 19, stmt)
                if let s = n.logicalSize { sqlite3_bind_int64(stmt, 20, s) }
                if let s = n.allocatedSize { sqlite3_bind_int64(stmt, 21, s) }
                if let d = n.modified { sqlite3_bind_double(stmt, 22, d.timeIntervalSince1970) }
                sqlite3_bind_int(stmt, 23, n.modified == nil ? 1 : 0)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw IndexError.database }
            }
            try exec("UPDATE metadata SET highWater=MAX(highWater,(SELECT COALESCE(MAX(id),0) FROM nodes))")
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func issue(path: String, message: String) {
        var s: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT INTO issues VALUES(?,?)", -1, &s, nil)
        defer { sqlite3_finalize(s) }; bind(path, to: 1, s); bind(message, to: 2, s); sqlite3_step(s)
        var mark: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE nodes SET incomplete=1 WHERE path=? OR path=? OR parent IS NULL", -1, &mark, nil)
        defer { sqlite3_finalize(mark) }; bind(path, to: 1, mark); bind(URL(fileURLWithPath: path).deletingLastPathComponent().path, to: 2, mark); sqlite3_step(mark)
    }
    public func issues() -> [ScanIssue] {
        var s: OpaquePointer?; sqlite3_prepare_v2(db, "SELECT path,message FROM issues LIMIT 500", -1, &s, nil)
        defer { sqlite3_finalize(s) }; var result: [ScanIssue] = []
        while sqlite3_step(s) == SQLITE_ROW { result.append(ScanIssue(path: string(s,0),message: string(s,1))) }; return result
    }
    public func aggregate() throws {
        try exec("BEGIN TRANSACTION")
        do { try aggregateInsideTransaction(); try exec("COMMIT"); revision &+= 1 }
        catch { try? exec("ROLLBACK"); throw error }
    }
    func aggregateInsideTransaction(affectedOnly: Bool = false) throws {
        let leafScope = affectedOnly ? " AND identity IN (SELECT identity FROM refresh_affected)" : ""
        let directoryScope = affectedOnly ? " AND id IN (SELECT id FROM refresh_directories)" : ""
        // Reassign counted bytes from raw metadata across the entire indexed scope.
        try exec("""
        UPDATE nodes SET logical=rawLogical,allocated=rawAllocated,knownLogical=COALESCE(rawLogical,0),knownAllocated=COALESCE(rawAllocated,0),unknownLogical=rawLogical IS NULL,unknownAllocated=rawAllocated IS NULL,latestModified=modified,unknownModified=modified IS NULL WHERE directory=0\(leafScope);
        UPDATE nodes SET logical=0,allocated=0,knownLogical=0,knownAllocated=0,unknownLogical=0,unknownAllocated=0 WHERE directory=0 AND symlink=0 AND identity<>'' AND id<>(SELECT MIN(alias.id) FROM nodes alias WHERE alias.identity=nodes.identity AND alias.directory=0 AND alias.symlink=0)\(leafScope);
        """)
        // Path depth remains valid when stable IDs survive subtree replacements.
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM nodes WHERE directory=1\(directoryScope) ORDER BY length(path) DESC", -1, &s, nil) == SQLITE_OK else { throw IndexError.database }
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
