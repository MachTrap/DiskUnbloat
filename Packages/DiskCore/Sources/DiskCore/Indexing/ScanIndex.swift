import Foundation
import CSQLite

public actor ScanIndex {
    private var db: OpaquePointer?
    public nonisolated let url: URL
    public private(set) var revision: UInt64 = 0
    public init(url: URL) throws {
        self.url = url
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw IndexError.database }
        db = handle
        let schema = """
        PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS nodes(id INTEGER PRIMARY KEY,parent INTEGER,path TEXT,name TEXT,directory INTEGER,package INTEGER,symlink INTEGER,logical INTEGER,allocated INTEGER,modified REAL,identity TEXT,insidePackage INTEGER,incomplete INTEGER NOT NULL DEFAULT 0,fingerprint TEXT,searchName TEXT,knownLogical INTEGER NOT NULL DEFAULT 0,knownAllocated INTEGER NOT NULL DEFAULT 0,unknownLogical INTEGER NOT NULL DEFAULT 0,unknownAllocated INTEGER NOT NULL DEFAULT 0,rawLogical INTEGER,rawAllocated INTEGER,category TEXT,latestModified REAL,unknownModified INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS parent_index ON nodes(parent);
        CREATE INDEX IF NOT EXISTS size_index ON nodes(knownAllocated DESC);
        CREATE INDEX IF NOT EXISTS path_index ON nodes(path);
        CREATE INDEX IF NOT EXISTS identity_index ON nodes(identity);
        CREATE INDEX IF NOT EXISTS category_index ON nodes(category);
        CREATE TABLE IF NOT EXISTS issues(path TEXT,message TEXT);
        CREATE TABLE IF NOT EXISTS metadata(highWater INTEGER);
        INSERT INTO metadata SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM metadata);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(handle); throw IndexError.database }
    }
    public enum IndexError: Error { case database }
    public func close() { if let db { sqlite3_close(db); self.db = nil } }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw IndexError.database }
    }
    private func execute(_ sql: String, strings: [String]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw IndexError.database }
        defer { sqlite3_finalize(stmt) }
        for (i,value) in strings.enumerated() { bind(value, to: Int32(i+1), stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw IndexError.database }
    }
    public func insert(_ nodes: [FileNode]) throws {
        try exec("BEGIN TRANSACTION")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO nodes(id,parent,path,name,directory,package,symlink,logical,allocated,modified,identity,insidePackage,fingerprint,searchName,knownLogical,knownAllocated,unknownLogical,unknownAllocated) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw IndexError.database }
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
                bind(n.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), to: 14, stmt)
                sqlite3_bind_int64(stmt, 15, n.knownLogicalSize); sqlite3_bind_int64(stmt, 16, n.knownAllocatedSize)
                sqlite3_bind_int64(stmt, 17, Int64(n.unknownLogicalCount)); sqlite3_bind_int64(stmt, 18, Int64(n.unknownAllocatedCount))
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw IndexError.database }
            }
            try exec("UPDATE nodes SET rawLogical=logical,rawAllocated=allocated,latestModified=modified,unknownModified=CASE WHEN modified IS NULL THEN 1 ELSE 0 END WHERE category IS NULL")
            var classify: OpaquePointer?
            sqlite3_prepare_v2(db, "UPDATE nodes SET category=? WHERE id=?", -1, &classify, nil)
            defer { sqlite3_finalize(classify) }
            for n in nodes {
                sqlite3_reset(classify); bind(n.category.rawValue, to: 1, classify); sqlite3_bind_int64(classify, 2, n.id)
                guard sqlite3_step(classify) == SQLITE_DONE else { throw IndexError.database }
            }
            try exec("UPDATE metadata SET highWater=MAX(highWater,(SELECT COALESCE(MAX(id),0) FROM nodes))")
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    private func bind(_ string: String, to column: Int32, _ stmt: OpaquePointer?) {
        _ = string.withCString { sqlite3_bind_text(stmt, column, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
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
    private func aggregateInsideTransaction(affectedOnly: Bool = false) throws {
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
    public func node(_ id: Int64) -> FileNode? { read("SELECT * FROM nodes WHERE id=\(id)").first }
    private func predicate(_ q: FileQuery) -> (String, [String]) {
        var clauses = ["1=1"]
        var strings: [String] = []
        if q.knownSizesOnly { clauses.append(q.metric == .allocated ? "allocated IS NOT NULL" : "logical IS NOT NULL") }
        if !q.inspectPackages { clauses.append("insidePackage=0") }
        if q.leafResults && q.cleanupRule?.isCache != true { clauses.append(q.inspectPackages ? "directory=0" : "(directory=0 OR package=1)") }
        clauses.append("parent IS NOT NULL")
        if let path = q.subtreePath {
            // A binary prefix range is case-sensitive and uses the path index.
            clauses.append("path>=? COLLATE BINARY AND path<? COLLATE BINARY")
            strings.append(path == "/" ? "/" : path + "/")
            strings.append(path == "/" ? "0" : path + "0")
        }
        if let p = q.parentID { clauses.append("parent=\(p)") }
        if !q.search.isEmpty { clauses.append("instr(searchName,?)>0"); strings.append(q.search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) }
        if q.minimumSize > 0 { clauses.append("\(q.metric == .allocated ? "knownAllocated" : "knownLogical")>=\(q.minimumSize)") }
        if let date = q.olderThan { clauses.append("modified<\(date.timeIntervalSince1970)") }
        if !q.fileExtension.isEmpty { clauses.append("lower(path) LIKE ? ESCAPE '\\'"); strings.append("%." + escapeLike(q.fileExtension.lowercased())) }
        if let suggestion = q.suggestion {
            // Regenerable and cache candidates are folders; the other suggestions are leaf entries.
            clauses.append(suggestion == .regenerable || suggestion == .caches ? "insidePackage=0 AND symlink=0" : "directory=0 AND insidePackage=0 AND symlink=0")
            let cutoff = Date().addingTimeInterval(-Double(max(1, q.ageDays)) * 86400).timeIntervalSince1970
            switch suggestion {
            case .large: clauses.append("allocated>=\(q.largeThreshold)")
            case .downloads: clauses.append("path LIKE '%/Downloads/%' AND modified<\(cutoff)")
            case .archives: clauses.append("modified<\(cutoff) AND (lower(name) LIKE '%.zip' OR lower(name) LIKE '%.dmg' OR lower(name) LIKE '%.pkg' OR lower(name) LIKE '%.tar' OR lower(name) LIKE '%.gz')")
            case .regenerable: clauses.append("directory=1 AND " + regenerableNameSQL(&strings))
            case .caches:
                // All curated cache locations, not only ~/Library/Caches.
                if let home = q.userHome {
                    let parts = CleanupRule.userCaches.roots(relativeTo: home).map { root -> String in
                        if root.candidate == .rootItself { strings.append(root.path); return "path=?" }
                        strings += [root.path + "/", root.path + "0"]
                        return "path>=? COLLATE BINARY AND path<? COLLATE BINARY"
                    }
                    clauses.append("(" + parts.joined(separator: " OR ") + ")")
                } else if let root = q.cacheRootPath {
                    clauses.append("path>=? COLLATE BINARY AND path<? COLLATE BINARY")
                    strings.append(root + "/"); strings.append(root + "0")
                } else { clauses.append("path LIKE '/Users/%/Library/Caches/%'") }
            }
        }
        if let rule = q.cleanupRule {
            clauses.append("symlink=0 AND insidePackage=0 AND incomplete=0")
            if !rule.isCache && rule != .regenerable { clauses.append(q.inspectPackages ? "directory=0" : "(directory=0 OR package=1)") }
            if rule == .large { clauses.append("allocated>=\(q.largeThreshold)") }
            else if rule == .regenerable {
                // Regenerable folders are identified by name anywhere in the scanned tree.
                clauses.append("directory=1 AND " + regenerableNameSQL(&strings))
            } else {
                let roots = q.userHome.flatMap { rule.roots(relativeTo: $0) } ?? []
                if roots.isEmpty {
                    if rule.isCache || rule == .downloads { clauses.append("0=1") }
                    if rule == .archives {
                        let cutoff = Date().addingTimeInterval(-Double(max(1, q.ageDays)) * 86400).timeIntervalSince1970
                        clauses.append("category='Archives' AND unknownModified=0 AND latestModified<\(cutoff) AND unknownAllocated=0")
                    }
                } else {
                    // Age gating applies per root so version-staleness roots can keep the newest entry instead.
                    let rootClauses = roots.map { root in
                        var parts: [String] = []
                        if root.candidate == .rootItself {
                            parts.append("path=?"); strings.append(root.path)
                            if rule.isCache || rule == .downloads {
                                let days = rule.isCache ? q.cacheAgeDays : q.ageDays
                                let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970
                                parts.append("unknownModified=0 AND latestModified<\(cutoff) AND unknownAllocated=0")
                            }
                        } else {
                            parts.append("path>=? COLLATE BINARY AND path<? COLLATE BINARY")
                            strings += [root.path + "/", root.path + "0"]
                            if root.candidate == .childrenKeepingNewest {
                                // Exclude the subtree of the most recently used direct child.
                                parts.append("NOT(path>=(SELECT ?||'/'||name FROM nodes WHERE parent=(SELECT id FROM nodes WHERE path=?) ORDER BY COALESCE(latestModified,0) DESC,name DESC LIMIT 1) AND path<(SELECT ?||'/'||name FROM nodes WHERE parent=(SELECT id FROM nodes WHERE path=?) ORDER BY COALESCE(latestModified,0) DESC,name DESC LIMIT 1)||'0')")
                                strings += [root.path, root.path, root.path, root.path]
                            } else if rule.isCache || rule == .downloads {
                                let days = rule.isCache ? q.cacheAgeDays : q.ageDays
                                let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970
                                parts.append("unknownModified=0 AND latestModified<\(cutoff) AND unknownAllocated=0")
                            }
                            if rule.isCache {
                                // Direct cache-root children are disjoint; narrower scans fall back to leaf entries.
                                parts.append("(parent=(SELECT id FROM nodes WHERE path=?) OR (NOT EXISTS(SELECT 1 FROM nodes WHERE path=?) AND directory=0))")
                                strings += [root.path, root.path]
                            }
                        }
                        return "(" + parts.joined(separator: " AND ") + ")"
                    }
                    clauses.append("(" + rootClauses.joined(separator: " OR ") + ")")
                }
            }
            for path in q.excludedCandidatePaths {
                clauses.append("NOT(path=? OR (path>=? COLLATE BINARY AND path<? COLLATE BINARY))")
                strings += [path,path + "/",path + "0"]
            }
            // Curated roots may legitimately live under managed-application trees; those blanket
            // exclusions are dropped only when a declared root requires it.
            let roots = q.userHome.flatMap { rule.roots(relativeTo: $0) } ?? []
            var generic = ["path NOT LIKE '/usr/%'", "path NOT LIKE '/bin/%'", "path NOT LIKE '/sbin/%'", "path NOT LIKE '/dev/%'", "path NOT LIKE '/etc/%'", "path NOT LIKE '/var/%'", "path NOT LIKE '/System/%'", "path NOT LIKE '/Library/%'", "path NOT LIKE '/Applications/%'", "path NOT LIKE '/private/%'", "path NOT LIKE '%/Library/Containers/%'", "path NOT LIKE '%/Library/Group Containers/%'", "path NOT LIKE '%/Library/Application Support/%'"]
            if roots.contains(where: { $0.path.contains("/Library/Group Containers/") }) { generic.removeAll { $0.contains("Group Containers") } }
            if roots.contains(where: { $0.path.contains("/Library/Application Support/") }) { generic.removeAll { $0.contains("Application Support") } }
            clauses += generic
        }
        for path in q.hiddenPaths {
            clauses.append("NOT(path=? OR (path>=? COLLATE BINARY AND path<? COLLATE BINARY))")
            strings += [path,path + "/",path + "0"]
        }
        return (clauses.joined(separator: " AND "), strings)
    }
    public func query(_ q: FileQuery) -> [FileNode] {
        let (whereSQL, strings) = predicate(q)
        let order = q.sortByName ? "name COLLATE NOCASE" : q.metric == .allocated ? "knownAllocated" : "knownLogical"
        return read("SELECT * FROM nodes WHERE \(whereSQL) ORDER BY \(order) \(q.ascending ? "ASC" : "DESC"),id LIMIT \(max(1, min(q.limit, 10000))) OFFSET \(max(0, q.offset))", strings: strings)
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

    public func validateBranch(_ request: BranchRefreshRequest) throws {
        guard let original = node(request.nodeID), original.identity == request.identity else { throw RefreshError.changedFolder }
        var current: FileNode? = original
        while let item = current {
            let identity = try FileIdentity.read(item.url)
            guard identity.identity == item.identity, !identity.link, identity.directory else { throw RefreshError.changedFolder }
            current = item.parentID.flatMap { node($0) }
        }
    }

    /// The staging connection must be closed before attachment. No suspension occurs during commit.
    public func replaceBranch(_ request: BranchRefreshRequest, stagingURL: URL) throws -> BranchRefreshResult {
        guard let original = node(request.nodeID), original.identity == request.identity,
              try FileIdentity.read(original.url).identity == request.identity else { throw RefreshError.changedFolder }
        try validateBranch(request)
        var ancestor = original.parentID.flatMap { node($0) }
        while let current = ancestor {
            let identity = try FileIdentity.read(current.url)
            guard identity.identity == current.identity, !identity.link else { throw RefreshError.changedFolder }
            ancestor = current.parentID.flatMap { node($0) }
        }
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(db, "ATTACH DATABASE ? AS incoming", -1, &attach, nil) == SQLITE_OK else { throw IndexError.database }
        bind(stagingURL.path, to: 1, attach)
        let attached = sqlite3_step(attach); sqlite3_finalize(attach)
        guard attached == SQLITE_DONE else { throw IndexError.database }
        defer { try? exec("DETACH DATABASE incoming") }
        try exec("BEGIN IMMEDIATE")
        do {
            guard read("SELECT * FROM incoming.nodes WHERE parent IS NULL").first?.identity == original.identity else { throw RefreshError.changedFolder }
            let prefix = original.path == "/" ? "/" : original.path + "/"
            let upper = original.path == "/" ? "0" : original.path + "0"
            try exec("CREATE TEMP TABLE refresh_affected(identity TEXT PRIMARY KEY)")
            try exec("CREATE TEMP TABLE refresh_directories(id INTEGER PRIMARY KEY)")
            defer { try? exec("DROP TABLE refresh_affected; DROP TABLE refresh_directories") }
            try exec("INSERT OR IGNORE INTO refresh_affected SELECT identity FROM incoming.nodes WHERE directory=0")
            try execute("INSERT OR IGNORE INTO refresh_affected SELECT identity FROM nodes WHERE directory=0 AND (path=? OR (path>=? COLLATE BINARY AND path<? COLLATE BINARY))", strings: [original.path,prefix,upper])
            var mapping: OpaquePointer?
            try exec("CREATE TEMP TABLE refresh_ids(oldID INTEGER PRIMARY KEY,newID INTEGER,path TEXT)")
            defer { try? exec("DROP TABLE refresh_ids") }
            let sql = """
            INSERT INTO refresh_ids SELECT fresh.id,COALESCE(old.id,(SELECT highWater FROM metadata)+fresh.id),fresh.path
            FROM incoming.nodes fresh LEFT JOIN nodes old ON fresh.path=old.path AND fresh.identity=old.identity
            """
            try exec(sql)
            // Root ID must remain stable even when other IDs have been allocated previously.
            try exec("UPDATE refresh_ids SET newID=\(original.id) WHERE oldID=1")
            sqlite3_prepare_v2(db, "DELETE FROM nodes WHERE path=? OR (path>=? COLLATE BINARY AND path<? COLLATE BINARY)", -1, &mapping, nil)
            bind(original.path, to: 1, mapping); bind(prefix, to: 2, mapping); bind(upper, to: 3, mapping)
            guard sqlite3_step(mapping) == SQLITE_DONE else { sqlite3_finalize(mapping); throw IndexError.database }; sqlite3_finalize(mapping)
            let parent = original.parentID.map(String.init) ?? "NULL"
            try exec("""
            INSERT INTO nodes SELECT ids.newID,CASE WHEN fresh.parent IS NULL THEN \(parent) ELSE parents.newID END,
            fresh.path,fresh.name,fresh.directory,fresh.package,fresh.symlink,fresh.logical,fresh.allocated,fresh.modified,fresh.identity,
            MAX(fresh.insidePackage,\(original.packageAncestor ? 1 : 0)),fresh.incomplete,fresh.fingerprint,fresh.searchName,fresh.knownLogical,fresh.knownAllocated,fresh.unknownLogical,fresh.unknownAllocated,
            fresh.rawLogical,fresh.rawAllocated,fresh.category,fresh.latestModified,fresh.unknownModified
            FROM incoming.nodes fresh JOIN refresh_ids ids ON ids.oldID=fresh.id LEFT JOIN refresh_ids parents ON parents.oldID=fresh.parent;
            """)
            var issues: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM issues WHERE path=? OR (path>=? COLLATE BINARY AND path<? COLLATE BINARY)", -1, &issues, nil)
            bind(original.path, to: 1, issues); bind(prefix, to: 2, issues); bind(upper, to: 3, issues); sqlite3_step(issues); sqlite3_finalize(issues)
            try exec("INSERT INTO issues SELECT * FROM incoming.issues")
            // Include all refreshed directories and every ancestor of an affected hard-link alias.
            try execute("""
            INSERT OR IGNORE INTO refresh_directories
            WITH RECURSIVE ancestors(id) AS (
                SELECT id FROM nodes WHERE directory=1 AND (path=? OR (path>=? COLLATE BINARY AND path<? COLLATE BINARY))
                UNION SELECT parent FROM nodes WHERE directory=0 AND identity IN (SELECT identity FROM refresh_affected)
                UNION SELECT nodes.parent FROM nodes JOIN ancestors ON nodes.id=ancestors.id WHERE nodes.parent IS NOT NULL
            ) SELECT id FROM ancestors WHERE id IS NOT NULL
            """, strings: [original.path,prefix,upper])
            try exec("UPDATE nodes SET incomplete=0 WHERE id IN (SELECT id FROM refresh_directories); UPDATE nodes SET incomplete=1 WHERE id IN (SELECT id FROM refresh_directories) AND EXISTS(SELECT 1 FROM issues WHERE issues.path=nodes.path OR issues.path=nodes.path||'/'||substr(issues.path,length(nodes.path)+2))")
            try aggregateInsideTransaction(affectedOnly: true)
            guard try FileIdentity.read(original.url).identity == request.identity else { throw RefreshError.changedFolder }
            try exec("UPDATE metadata SET highWater=MAX(highWater,(SELECT COALESCE(MAX(id),0) FROM nodes))")
            try exec("COMMIT"); revision &+= 1
            return BranchRefreshResult(rootID: original.id, revision: revision)
        } catch { try? exec("ROLLBACK"); throw error }
    }

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
    private func escapeLike(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") }
    /// Shared name match for regenerable folders, used by both the rule and its suggestion.
    private func regenerableNameSQL(_ strings: inout [String]) -> String {
        let names = CleanupRule.regenerableNames
        let exact = names.map { _ in "name=?" }.joined(separator: " OR ")
        let prefixes = CleanupRule.regenerableNamePrefixes
        let like = prefixes.map { _ in "name LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
        strings += names + prefixes.map { escapeLike($0) + "%" }
        return "(\(exact)\(prefixes.isEmpty ? "" : " OR \(like)"))"
    }
    public func ancestorIdentities(for ids: [Int64]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let nodes = read("WITH RECURSIVE ancestry(id) AS (SELECT parent FROM nodes WHERE id IN (\(ids.map(String.init).joined(separator: ","))) UNION SELECT nodes.parent FROM nodes JOIN ancestry ON nodes.id=ancestry.id WHERE nodes.parent IS NOT NULL) SELECT nodes.* FROM nodes JOIN ancestry ON nodes.id=ancestry.id")
        return Dictionary(nodes.map { ($0.path, $0.identity) }, uniquingKeysWith: { first, _ in first })
    }
    public func remove(paths: [String]) throws {
        for path in paths {
            var s: OpaquePointer?; sqlite3_prepare_v2(db, "DELETE FROM nodes WHERE path=? OR path LIKE ? ESCAPE '\\'", -1, &s, nil)
            bind(path, to: 1, s); bind(escapeLike(path) + "/%", to: 2, s)
            guard sqlite3_step(s) == SQLITE_DONE else { sqlite3_finalize(s); throw IndexError.database }; sqlite3_finalize(s)
        }
        try aggregate()
    }
    private func string(_ s: OpaquePointer?, _ c: Int32) -> String { sqlite3_column_text(s, c).map { String(cString: $0) } ?? "" }
    private func read(_ sql: String, strings: [String] = []) -> [FileNode] {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        for (i, value) in strings.enumerated() { bind(value, to: Int32(i + 1), s) }
        var result: [FileNode] = []
        while sqlite3_step(s) == SQLITE_ROW {
            result.append(FileNode(id: sqlite3_column_int64(s, 0), parentID: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 1), path: string(s, 2), name: string(s, 3), isDirectory: sqlite3_column_int(s, 4) != 0, isPackage: sqlite3_column_int(s, 5) != 0, isSymbolicLink: sqlite3_column_int(s, 6) != 0, logicalSize: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 7), allocatedSize: sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 8), modified: sqlite3_column_type(s, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 9)), identity: string(s, 10), fingerprint: sqlite3_column_type(s, 13) == SQLITE_NULL ? nil : string(s, 13), packageAncestor: sqlite3_column_int(s, 11) != 0, knownLogicalSize: sqlite3_column_int64(s,15), knownAllocatedSize: sqlite3_column_int64(s,16), unknownLogicalCount: Int(sqlite3_column_int64(s,17)), unknownAllocatedCount: Int(sqlite3_column_int64(s,18)), latestContentModification: sqlite3_column_type(s,22) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s,22)), unknownModificationCount: Int(sqlite3_column_int64(s,23))))
        }; return result
    }
}
