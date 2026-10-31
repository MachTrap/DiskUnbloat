import Foundation
import CSQLite

public actor ScanIndex {
    var db: OpaquePointer?
    public nonisolated let url: URL
    public internal(set) var revision: UInt64 = 0
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
    // A fixed locale keeps search folding deterministic and cheaper than the current locale.
    static let searchLocale = Locale(identifier: "en_US_POSIX")
    func folded(_ string: String) -> String { string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Self.searchLocale) }
    public func close() { if let db { sqlite3_close(db); self.db = nil } }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw IndexError.database }
    }
    func execute(_ sql: String, strings: [String]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw IndexError.database }
        defer { sqlite3_finalize(stmt) }
        for (i,value) in strings.enumerated() { bind(value, to: Int32(i+1), stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw IndexError.database }
    }
    func bind(_ string: String, to column: Int32, _ stmt: OpaquePointer?) {
        _ = string.withCString { sqlite3_bind_text(stmt, column, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    func escapeLike(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") }
    func string(_ s: OpaquePointer?, _ c: Int32) -> String { sqlite3_column_text(s, c).map { String(cString: $0) } ?? "" }
    func read(_ sql: String, strings: [String] = []) -> [FileNode] {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        for (i, value) in strings.enumerated() { bind(value, to: Int32(i + 1), s) }
        var result: [FileNode] = []
        while sqlite3_step(s) == SQLITE_ROW {
            result.append(FileNode(id: sqlite3_column_int64(s, 0), parentID: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 1), path: string(s, 2), name: string(s, 3), isDirectory: sqlite3_column_int(s, 4) != 0, isPackage: sqlite3_column_int(s, 5) != 0, isSymbolicLink: sqlite3_column_int(s, 6) != 0, logicalSize: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 7), allocatedSize: sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 8), modified: sqlite3_column_type(s, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 9)), identity: string(s, 10), fingerprint: sqlite3_column_type(s, 13) == SQLITE_NULL ? nil : string(s, 13), packageAncestor: sqlite3_column_int(s, 11) != 0, knownLogicalSize: sqlite3_column_int64(s,15), knownAllocatedSize: sqlite3_column_int64(s,16), unknownLogicalCount: Int(sqlite3_column_int64(s,17)), unknownAllocatedCount: Int(sqlite3_column_int64(s,18)), latestContentModification: sqlite3_column_type(s,22) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s,22)), unknownModificationCount: Int(sqlite3_column_int64(s,23))))
        }; return result
    }
    /// Lightweight row reader for browsing and map queries: skips `searchName` and the raw
    /// accounting columns that no `FileNode` reader consumes. Identity/fingerprint are kept
    /// so cleanup validation still works on selected rows.
    func readRows(_ sql: String, strings: [String] = []) -> [FileNode] {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        for (i, value) in strings.enumerated() { bind(value, to: Int32(i + 1), s) }
        var result: [FileNode] = []
        while sqlite3_step(s) == SQLITE_ROW {
            result.append(FileNode(id: sqlite3_column_int64(s, 0), parentID: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 1), path: string(s, 2), name: string(s, 3), isDirectory: sqlite3_column_int(s, 4) != 0, isPackage: sqlite3_column_int(s, 5) != 0, isSymbolicLink: sqlite3_column_int(s, 6) != 0, logicalSize: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 7), allocatedSize: sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 8), modified: sqlite3_column_type(s, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 9)), identity: string(s, 10), fingerprint: sqlite3_column_type(s, 11) == SQLITE_NULL ? nil : string(s, 11), packageAncestor: sqlite3_column_int(s, 12) != 0, knownLogicalSize: sqlite3_column_int64(s, 13), knownAllocatedSize: sqlite3_column_int64(s, 14), unknownLogicalCount: Int(sqlite3_column_int64(s, 15)), unknownAllocatedCount: Int(sqlite3_column_int64(s, 16)), latestContentModification: sqlite3_column_type(s, 17) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 17)), unknownModificationCount: Int(sqlite3_column_int64(s, 18))))
        }; return result
    }
}
