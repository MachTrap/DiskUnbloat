import CSQLite

extension ScanIndex {
    func duplicateCandidateSnapshot(
        minimumSize: Int64,
        eligible: @Sendable (FileNode) -> Bool
    ) throws -> (revision: UInt64, groups: [[DuplicateCandidate]]) {
        try validateDuplicateRevision(revision)
        let filter = "directory=0 AND symlink=0 AND insidePackage=0 AND summary=0 AND incomplete=0 AND rawLogical>=?"
        let sql = """
        SELECT \(Self.rowColumns),rawLogical FROM nodes WHERE \(filter) AND rawLogical IN (
          SELECT rawLogical FROM nodes WHERE \(filter) GROUP BY rawLogical HAVING COUNT(DISTINCT identity)>1)
        ORDER BY rawLogical DESC, logical DESC, path COLLATE BINARY
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw IndexError.database }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, max(1, minimumSize))
        sqlite3_bind_int64(statement, 2, max(1, minimumSize))
        var groups: [[DuplicateCandidate]] = []
        var group: [DuplicateCandidate] = []
        var size: Int64?
        var seen: Set<String> = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            let rawSize = sqlite3_column_int64(statement, 20)
            if size != rawSize {
                if group.count > 1 { groups.append(group) }
                group = []
                seen.removeAll(keepingCapacity: true)
                size = rawSize
            }
            let node = decodeRow(statement)
            // Apply scope before collapsing aliases. Prefer the inode's counted row if it
            // is eligible, so known bytes follow the same accounting as the cleanup queue.
            if eligible(node), seen.insert(node.identity).inserted {
                group.append(DuplicateCandidate(node: node, size: rawSize))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw IndexError.database }
        if group.count > 1 { groups.append(group) }
        return (revision, groups)
    }

    func duplicateFolderTree(
        at path: String, revision: UInt64, limit: Int,
        eligible: @Sendable (FileNode) -> Bool
    ) throws -> DuplicateFolderTree? {
        try validateDuplicateRevision(revision)
        let range = path.pathRange
        let sql = """
        SELECT \(Self.rowColumns),rawLogical,incomplete FROM nodes
        WHERE path=? OR (path>=? COLLATE BINARY AND path<? COLLATE BINARY)
        ORDER BY path COLLATE BINARY LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw IndexError.database }
        defer { sqlite3_finalize(statement) }
        bind(path, to: 1, statement)
        bind(range.lower, to: 2, statement)
        bind(range.upper, to: 3, statement)
        sqlite3_bind_int64(statement, 4, Int64(limit) + 2)

        var root: FileNode?
        var entries: [DuplicateFolderTree.Entry] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            let node = decodeRow(statement)
            guard sqlite3_column_int(statement, 21) == 0,
                  !node.isSymbolicLink, !node.isPackage, !node.packageAncestor, !node.isSummarized,
                  node.unknownLogicalCount == 0, eligible(node) else { return nil }
            if root == nil {
                guard node.path == path, node.isDirectory, let parent = node.parentID,
                      self.node(parent)?.isGroupRoot != true else { return nil }
                root = node
            } else {
                if entries.count == limit { throw DuplicateFolderCoverageError.entryLimit }
                let size: Int64?
                if node.isDirectory { size = nil }
                else {
                    guard sqlite3_column_type(statement, 20) != SQLITE_NULL else { return nil }
                    size = sqlite3_column_int64(statement, 20)
                }
                let relativePath = String(decoding: node.path.utf8.dropFirst(path.utf8.count + 1), as: UTF8.self)
                entries.append(.init(relativePath: relativePath, node: node, size: size))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw IndexError.database }
        guard let root else { return nil }
        return DuplicateFolderTree(root: root, entries: entries)
    }

    func validateDuplicateRevision(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard db != nil, !bulkLoading, revision == expected else { throw DuplicateSearchError.staleIndex }
    }
}
