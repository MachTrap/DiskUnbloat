import Testing
import Foundation
import CSQLite
@testable import DiskCore

/// The bulk reader must agree with `lstat` (identity, fingerprint, sizes) and with
/// Foundation's package/hidden semantics, because cleanup validation re-reads items with
/// `FileIdentity.read` and compares the recorded fingerprint byte for byte.
@Test func bulkEntriesMatchLstatAndFoundation() throws {
    let f = try Fixture(); defer { f.dispose() }
    let file = try f.file("plain.bin", bytes: 12345)
    _ = try f.file(".dotfile", bytes: 10)
    _ = try f.file("Example.app/Contents/payload", bytes: 100)
    _ = try f.file("Thing.bundle/x", bytes: 1)
    _ = try f.file("folder.with.dots/x", bytes: 1)
    _ = try f.file("Project.xcodeproj/project.pbxproj", bytes: 1)
    try FileManager.default.linkItem(at: file, to: f.root.appendingPathComponent("hard"))
    try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("link"), withDestinationURL: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)

    var entries: [BulkEntry] = []
    try BulkDirectoryReader().read(f.root.path) { entries.append($0) }
    let detector = PackageDetector()
    #expect(Set(entries.map(\.name)) == Set(try FileManager.default.contentsOfDirectory(atPath: f.root.path)))
    for entry in entries {
        let url = f.root.appendingPathComponent(entry.name)
        let stat = try FileIdentity.read(url)
        #expect(entry.error == 0)
        #expect(entry.identity == stat.identity, "\(entry.name)")
        #expect(entry.fingerprint == stat.fingerprint, "\(entry.name)")
        #expect(entry.device == stat.device)
        #expect((entry.kind == .directory) == stat.directory)
        #expect((entry.kind == .symlink) == stat.link)
        #expect(entry.modificationDate == stat.modified)
        if entry.kind == .file {
            #expect(entry.size == stat.size, "\(entry.name)")
            #expect(entry.allocated == stat.allocated, "\(entry.name)")
            #expect(entry.links == UInt32(stat.links))
        }
        let values = try url.resourceValues(forKeys: [.isPackageKey, .isHiddenKey])
        if entry.kind == .directory {
            #expect(detector.isPackage(name: entry.name, bundleBit: entry.hasBundleBit) == (values.isPackage ?? false), "\(entry.name)")
        }
        #expect(entry.isHidden == (entry.name.hasPrefix(".") || values.isHidden == true), "\(entry.name)")
    }
}

@Test func summarizedFoldersAreMeasuredWholeAndStayAtomic() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("web/node_modules/a/index.js", bytes: 3000)
    _ = try f.file("web/node_modules/b/deep/lib.js", bytes: 5000)
    _ = try f.file("web/node_modules/.bin/tool", bytes: 700)
    _ = try f.file("web/src/app.js", bytes: 100)
    _ = try f.file("repo/.git/objects/ab/cdef", bytes: 4000)
    _ = try f.file("Media/Keep/clip.mov", bytes: 900)
    let old = Date(timeIntervalSince1970: 1_600_000_000), newest = Date(timeIntervalSince1970: 1_700_000_000)
    for path in ["web/node_modules/a/index.js", "web/node_modules/.bin/tool", "web/node_modules/a", "web/node_modules/b", "web/node_modules/b/deep", "web/node_modules/.bin", "web/node_modules"] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.root.appendingPathComponent(path).path)
    }
    try FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: f.root.appendingPathComponent("web/node_modules/b/deep/lib.js").path)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.root.appendingPathComponent("web/node_modules/b/deep").path)

    var options = ScanOptions()
    options.summarizedFolders = ["NODE_MODULES", ".git", f.root.appendingPathComponent("Media/Keep").path]
    let (index, final) = try await scan(f.root, options: options)
    #expect(final?.complete == true)
    let modules = try #require(await index.node(path: f.root.path + "/web/node_modules"))
    #expect(modules.isSummarized && modules.isDirectory)
    #expect(modules.logicalSize == 8700)
    #expect(modules.latestContentModification == newest)
    #expect(!modules.isBrowsable(inspectPackages: true))
    #expect(await index.childCount(of: modules.id, inspectPackages: true) == 0)
    #expect(await index.node(path: f.root.path + "/web/node_modules/a/index.js") == nil)
    #expect(await index.node(path: f.root.path + "/repo/.git")?.logicalSize == 4000)
    #expect(await index.node(path: f.root.path + "/Media/Keep")?.isSummarized == true)
    #expect(await index.node(path: f.root.path + "/Media")?.isSummarized == false)
    // Known bytes roll up through ordinary folders unchanged.
    #expect(await index.node(path: f.root.path + "/web")?.logicalSize == 8800)
    #expect(await index.node(1)?.logicalSize == 8800 + 4000 + 900)
    // Hidden entries inside a summary follow the hidden-files option too.
    options.includeHidden = false
    let (visible, _) = try await scan(f.root, options: options)
    #expect(await visible.node(path: f.root.path + "/web/node_modules")?.logicalSize == 8000)
    await destroy(visible)
    // An empty list indexes everything.
    options.summarizedFolders = []; options.includeHidden = true
    let (full, _) = try await scan(f.root, options: options)
    #expect(await full.node(path: f.root.path + "/web/node_modules/a/index.js")?.logicalSize == 3000)
    await destroy(full); await destroy(index)
}

@Test func scanRootIsNeverSummarized() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("node_modules/pkg/index.js", bytes: 50)
    var options = ScanOptions(); options.summarizedFolders = ["node_modules"]
    let (index, _) = try await scan(f.root.appendingPathComponent("node_modules"), options: options)
    #expect(await index.node(1)?.isSummarized == false)
    #expect(await index.node(path: f.root.path + "/node_modules/pkg")?.isSummarized == false)
    await destroy(index)
}

/// Every file of a wide, deep tree is indexed exactly once with its own parent, whatever
/// order the parallel workers finish in.
@Test func parallelScanIndexesEveryEntryOnce() async throws {
    let f = try Fixture(); defer { f.dispose() }
    var expected: [String: Int] = [:]
    for a in 0..<12 { for b in 0..<6 { for c in 0..<8 {
        let path = "d\(a)/e\(b)/f\(c).bin"; let bytes = 10 + a * 100 + b * 10 + c
        _ = try f.file(path, bytes: bytes); expected[f.root.path + "/" + path] = bytes
    } } }
    let (index, final) = try await scan(f.root)
    #expect(final?.complete == true)
    #expect(final?.items == 1 + 12 + 12 * 6 + expected.count)
    var q = FileQuery(); q.limit = 10000; q.leafResults = true
    let files = await index.query(q).filter { !$0.isDirectory }
    #expect(files.count == expected.count)
    for file in files {
        #expect(expected[file.path] == file.logicalSize.map(Int.init))
        let parent = try #require(await index.node(file.parentID ?? -1))
        #expect(parent.path == file.url.deletingLastPathComponent().path)
    }
    #expect(await index.node(1)?.logicalSize == Int64(expected.values.reduce(0, +)))
    await destroy(index)
}

/// Every aggregate column of every row, for comparing two aggregation strategies.
private func aggregateColumns(_ index: ScanIndex) async -> [String] {
    await index.aggregateSnapshot()
}
extension ScanIndex {
    func aggregateSnapshot() -> [String] {
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id,logical,allocated,knownLogical,knownAllocated,unknownLogical,unknownAllocated,latestModified,unknownModified,incomplete FROM nodes ORDER BY id", -1, &s, nil)
        defer { sqlite3_finalize(s) }
        var rows: [String] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append((0..<10).map { sqlite3_column_type(s, $0) == SQLITE_NULL ? "∅" : String(cString: sqlite3_column_text(s, $0)) }.joined(separator: "|"))
        }
        return rows
    }
    func indexNames() -> Set<String> {
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='nodes'", -1, &s, nil)
        defer { sqlite3_finalize(s) }
        var names: Set<String> = []
        while sqlite3_step(s) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(s, 0))) }
        return names
    }
}

/// The in-memory aggregation used after scans must match the SQL aggregation kept for
/// branch refreshes on every column, including the awkward cases.
@Test func inMemoryAggregationMatchesSQL() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let t0 = Date(timeIntervalSince1970: 1_600_000_000)
    func n(_ id: Int64, _ parent: Int64?, _ path: String, dir: Bool = false, size: Int64? = 0, modified: Date? = t0, identity: String? = nil, symlink: Bool = false, summarized: Bool = false, latest: Date? = nil) -> FileNode {
        FileNode(id: id, parentID: parent, path: path, name: (path as NSString).lastPathComponent, isDirectory: dir, isSymbolicLink: symlink, logicalSize: size, allocatedSize: size.map { $0 + 1 }, modified: modified, identity: identity ?? "id\(id)", latestContentModification: latest, isSummarized: summarized)
    }
    // A short root under the group wrapper exposes children-first ordering; the rest covers
    // hard links, symlinks, unknown sizes, incomplete and summarized folders, empty folders.
    let nodes = [
        n(1, nil, ScanGroup.path, dir: true, modified: nil, identity: ScanGroup.path),
        n(2, 1, "/a", dir: true),
        n(3, 2, "/a/x", size: 10, identity: "hard"), n(4, 2, "/a/y", size: 10, identity: "hard"),
        n(5, 2, "/a/link", size: 3, identity: "hard", symlink: true),
        n(6, 2, "/a/sub", dir: true, modified: nil),
        n(7, 6, "/a/sub/unknown", size: nil, modified: nil),
        n(8, 6, "/a/sub/late", size: 5, modified: t0.addingTimeInterval(500)),
        n(9, 2, "/a/denied", dir: true),
        n(10, 9, "/a/denied/f", size: 7),
        n(11, 2, "/a/node_modules", dir: true, size: 900, summarized: true, latest: t0.addingTimeInterval(900)),
        n(12, 2, "/a/broken_modules", dir: true, size: 40, summarized: true, latest: t0),
        n(13, 2, "/a/empty", dir: true),
        n(14, 1, "/Volumes/longer-root-path", dir: true),
        n(15, 14, "/Volumes/longer-root-path/z", size: 1, identity: "hard"),
    ]
    let a = try ScanIndex(url: f.root.appendingPathComponent("a.sqlite")), b = try ScanIndex(url: f.root.appendingPathComponent("b.sqlite"))
    for index in [a, b] {
        try await index.insert(nodes)
        await index.issue(path: "/a/denied", message: "denied")
        await index.issue(path: "/a/broken_modules", message: "partial")
    }
    try await a.aggregate()
    try await b.aggregateInsideTransaction()
    let memory = await aggregateColumns(a), sql = await aggregateColumns(b)
    #expect(memory == sql)
    // Spot checks: the alias with the higher id counts zero, the symlink keeps its size,
    // and the wrapper totals include both roots.
    #expect(await a.node(4)?.knownLogicalSize == 0)
    #expect(await a.node(3)?.knownLogicalSize == 10)
    #expect(await a.node(5)?.knownLogicalSize == 3)
    #expect(await a.node(1)?.knownLogicalSize == 10 + 3 + 5 + 7 + 900 + 40)
    #expect(await a.node(11)?.latestContentModification == t0.addingTimeInterval(900))
    let broken = await a.node(12)
    #expect(broken?.logicalSize == nil && broken?.knownLogicalSize == 40)
    await a.close(); await b.close()
}

/// A scan's bulk load drops secondary indexes, defers issue marks, and restores both on
/// aggregation — or on `endBulkLoad()` when a scan fails before aggregating.
@Test func bulkLoadDefersIndexesAndMarks() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let index = try f.index()
    let full = await index.indexNames()
    #expect(full.isSuperset(of: ScanIndex.secondaryIndexNames))
    try await index.beginBulkLoad()
    #expect(await index.indexNames().isDisjoint(with: ScanIndex.secondaryIndexNames))
    try await index.insert([
        FileNode(id: 1, parentID: nil, path: "/r", name: "r", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "r"),
        FileNode(id: 2, parentID: 1, path: "/r/d", name: "d", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "d"),
        FileNode(id: 3, parentID: 2, path: "/r/d/f", name: "f", isDirectory: false, logicalSize: 4, allocatedSize: 4, modified: nil, identity: "f"),
    ])
    await index.issue(path: "/r/d/gone", message: "denied")
    #expect(await index.node(2)?.allocatedSize == 0) // mark still deferred
    try await index.aggregate()
    #expect(await index.indexNames().isSuperset(of: ScanIndex.secondaryIndexNames))
    #expect(await index.node(2)?.allocatedSize == nil)
    #expect(await index.node(1)?.allocatedSize == nil)
    #expect(await index.node(2)?.knownAllocatedSize == 4)
    // Populated indexes never enter bulk mode; endBulkLoad restores a failed load.
    try await index.beginBulkLoad()
    #expect(await index.indexNames().isSuperset(of: ScanIndex.secondaryIndexNames))
    let failed = try ScanIndex(url: f.root.appendingPathComponent("failed.sqlite"))
    try await failed.beginBulkLoad(); try await failed.endBulkLoad(); try await failed.endBulkLoad()
    #expect(await failed.indexNames().isSuperset(of: ScanIndex.secondaryIndexNames))
    await index.close(); await failed.close()
}

/// Parent lookups (folder listings, child counts, refresh aggregation) must stay indexed
/// through the composite parent/size index now that no plain parent index exists.
@Test func parentLookupsUseTheCompositeIndex() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let index = try f.index()
    for sql in ["SELECT id FROM nodes WHERE parent=7", "SELECT COUNT(*) FROM nodes WHERE parent=7 AND insidePackage=0",
                "SELECT parent,COUNT(*) FROM nodes WHERE parent IN (1,2,3) GROUP BY parent",
                "SELECT COALESCE(SUM(knownLogical),0) FROM nodes WHERE parent=7"] {
        let plan = await index.queryPlan(sql)
        #expect(plan.contains("parent_size_index"), "\(sql): \(plan)")
    }
    await index.close()
}
extension ScanIndex {
    func queryPlan(_ sql: String) -> String {
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + sql, -1, &s, nil)
        defer { sqlite3_finalize(s) }
        var lines: [String] = []
        while sqlite3_step(s) == SQLITE_ROW { lines.append(String(cString: sqlite3_column_text(s, 3))) }
        return lines.joined(separator: "; ")
    }
}
