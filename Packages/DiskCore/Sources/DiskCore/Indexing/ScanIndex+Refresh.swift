import Foundation
import CSQLite

extension ScanIndex {
    public func validateBranch(_ request: BranchRefreshRequest) throws {
        guard let original = node(request.nodeID), original.identity == request.identity else { throw RefreshError.changedFolder }
        var current: FileNode? = original
        while let item = current {
            if item.isGroupRoot { current = item.parentID.flatMap { node($0) }; continue }
            let identity = try FileIdentity.read(item.url)
            guard identity.identity == item.identity, !identity.link, identity.directory else { throw RefreshError.changedFolder }
            current = item.parentID.flatMap { node($0) }
        }
    }

    /// Re-fetch and re-validate the target branch immediately before committing a refresh: index
    /// identity, filesystem identity, and every ancestor's identity. Synchronous — no suspension.
    private func validateForRefresh(_ request: BranchRefreshRequest) throws -> FileNode {
        guard let original = node(request.nodeID), original.identity == request.identity,
              try FileIdentity.read(original.url).identity == request.identity else { throw RefreshError.changedFolder }
        try validateBranch(request)
        var ancestor = original.parentID.flatMap { node($0) }
        while let current = ancestor {
            if current.isGroupRoot { ancestor = current.parentID.flatMap { node($0) }; continue }
            let identity = try FileIdentity.read(current.url)
            guard identity.identity == current.identity, !identity.link else { throw RefreshError.changedFolder }
            ancestor = current.parentID.flatMap { node($0) }
        }
        return original
    }

    /// The staging connection must be closed before attachment. No suspension occurs during commit.
    public func replaceBranch(_ request: BranchRefreshRequest, stagingURL: URL) throws -> BranchRefreshResult {
        let original = try validateForRefresh(request)
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(db, "ATTACH DATABASE ? AS incoming", -1, &attach, nil) == SQLITE_OK else { throw IndexError.database }
        bind(stagingURL.path, to: 1, attach)
        let attached = sqlite3_step(attach); sqlite3_finalize(attach)
        guard attached == SQLITE_DONE else { throw IndexError.database }
        defer { try? exec("DETACH DATABASE incoming") }
        try exec("BEGIN IMMEDIATE")
        do {
            guard read("SELECT * FROM incoming.nodes WHERE parent IS NULL").first?.identity == original.identity else { throw RefreshError.changedFolder }
            let range = original.path.pathRange; let prefix = range.lower; let upper = range.upper
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
    public func ancestorIdentities(for ids: [Int64]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let nodes = read("WITH RECURSIVE ancestry(id) AS (SELECT parent FROM nodes WHERE id IN (\(ids.map(String.init).joined(separator: ","))) UNION SELECT nodes.parent FROM nodes JOIN ancestry ON nodes.id=ancestry.id WHERE nodes.parent IS NOT NULL) SELECT nodes.* FROM nodes JOIN ancestry ON nodes.id=ancestry.id")
        return Dictionary(nodes.map { ($0.path, $0.identity) }, uniquingKeysWith: { first, _ in first })
    }
}
