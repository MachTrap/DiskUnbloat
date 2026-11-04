import Testing
import Foundation
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
