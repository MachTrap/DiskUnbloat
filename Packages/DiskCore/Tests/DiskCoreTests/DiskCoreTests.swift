import Testing
import Foundation
import CoreGraphics
@testable import DiskCore

struct Fixture {
    let root: URL
    init() throws {
        root = canonicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("DiskUnbloatTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ name: String, bytes: Int = 8192) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url); return url
    }
    func dispose() { try? FileManager.default.removeItem(at: root) }
    func index() throws -> ScanIndex { try ScanIndex(url: root.appendingPathComponent("index.sqlite")) }
}
func scan(_ root: URL, options: ScanOptions = .init()) async throws -> (ScanIndex, ScanSnapshot?) {
    let index = try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
    let stream = await ScanCoordinator().scan(ScanRequest(root: root, options: options), into: index)
    var final: ScanSnapshot?
    for await event in stream { if case .finished(let s) = event { final = s }; if case .failed(let error) = event { Issue.record(Comment(rawValue: error)) } }
    return (index, final)
}
func destroy(_ index: ScanIndex) async {
    let url = index.url; await index.close()
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
}
@Test func sizesLinksAndHiddenFiles() async throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let original = try fixture.file("visible.bin")
    _ = try fixture.file(".hidden")
    try FileManager.default.linkItem(at: original, to: fixture.root.appendingPathComponent("hardlink"))
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("cycle"), withDestinationURL: fixture.root)
    let (index, final) = try await scan(fixture.root)
    #expect(final?.complete == true)
    var query = FileQuery(); query.parentID = 1
    let nodes = await index.query(query)
    #expect(nodes.count == 4)
    #expect(nodes.contains { $0.isSymbolicLink })
    let linked = nodes.filter { $0.name == "visible.bin" || $0.name == "hardlink" }
    #expect(linked.reduce(0) { $0 + ($1.logicalSize ?? 0) } == 8192)
    let root = await index.node(1)
    #expect(root?.logicalSize == nodes.reduce(0) { $0 + ($1.logicalSize ?? 0) })
    await destroy(index)
    var options = ScanOptions(); options.includeHidden = false; options.exclusions = [original.path]
    let (filtered, _) = try await scan(fixture.root, options: options)
    let remaining = await filtered.query(query)
    #expect(!remaining.contains { $0.name == ".hidden" || $0.name == "visible.bin" })
    await destroy(filtered)
}
@Test func packageAccounting() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("Example.app/Contents/payload", bytes: 16000)
    let (index, _) = try await scan(f.root)
    var q = FileQuery(); q.parentID = 1
    let package = try #require(await index.query(q).first)
    #expect(package.isPackage)
    #expect(package.logicalSize == 16000)
    q.parentID = package.id; q.inspectPackages = true
    #expect(await index.query(q).allSatisfy(\.packageAncestor))
    await destroy(index)
}
@Test func unknownSizesAndSuggestions() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let index = try f.index()
    let old = Date().addingTimeInterval(-200 * 86400)
    let root = FileNode(id: 1, parentID: nil, path: f.root.path, name: "Root", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: old, identity: "root")
    let file = FileNode(id: 2, parentID: 1, path: f.root.path + "/Downloads/old.dmg", name: "old.dmg", isDirectory: false, logicalSize: 2_000_000_000, allocatedSize: nil, modified: old, identity: "file")
    try await index.insert([root, file]); try await index.aggregate()
    #expect(await index.node(1)?.allocatedSize == nil)
    var q = FileQuery(); q.suggestion = .archives
    #expect(await index.query(q).count == 1)
    q.suggestion = .large
    #expect(await index.query(q).isEmpty)
    await destroy(index)
}
@Test func mapCoversBoundsWithoutOverlaps() {
    let nodes = (1...100).map { FileNode(id: Int64($0), parentID: 0, path: "/\($0)", name: "\($0)", isDirectory: false, logicalSize: Int64($0 * 1000), allocatedSize: Int64($0 * 1000), modified: nil, identity: "\($0)") }
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    let tiles = Treemap.layout(nodes, in: bounds)
    #expect(abs(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height } - 400000) < 0.001)
    for (i, a) in tiles.enumerated() {
        #expect(a.rect.minX >= -0.001 && a.rect.maxX <= 800.001 && a.rect.minY >= -0.001 && a.rect.maxY <= 500.001)
        for b in tiles.dropFirst(i + 1) { let overlap = a.rect.intersection(b.rect); #expect(overlap.isNull || overlap.width * overlap.height < 0.001) }
    }
    #expect(Treemap.layout([], in: bounds).isEmpty)
}
@Test func cleanupNormalizesAndRejectsChanges() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let a = try f.file("folder/a"); let b = try f.file("b")
    let (index, _) = try await scan(f.root)
    var q = FileQuery(); q.limit = 100
    let nodes = await index.query(q)
    let folder = try #require(nodes.first { $0.name == "folder" }); let child = try #require(nodes.first { $0.path == a.path }); let bn = try #require(nodes.first { $0.path == b.path })
    let plan = CleanupPlan(root: f.root, items: [child, folder, folder], mode: .permanent)
    #expect(plan.items.count == 1)
    try Data(repeating: 2, count: 32768).write(to: b)
    let changed = await CleanupService().execute(CleanupPlan(root: f.root, items: [bn], mode: .permanent))
    #expect(changed.first?.succeeded == false)
    #expect(FileManager.default.fileExists(atPath: b.path))
    let result = await CleanupService().execute(plan)
    #expect(result.first?.succeeded == true, "\(result.first?.message ?? "No result")")
    #expect(!FileManager.default.fileExists(atPath: a.path))
    let root = try #require(await index.node(1))
    #expect(CleanupSafety.blockedReason(root, root: f.root) != nil)
    await destroy(index)
}
@Test func replacedAncestorIsRejected() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("folder/a")
    let (index, _) = try await scan(f.root)
    let nodes = await index.query(FileQuery()); let child = try #require(nodes.first { $0.name == "a" })
    try FileManager.default.moveItem(at: f.root.appendingPathComponent("folder"), to: f.root.appendingPathComponent("renamed"))
    try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("folder"), withDestinationURL: f.root.appendingPathComponent("renamed"))
    let results = await CleanupService().execute(CleanupPlan(root: f.root, items: [child], mode: .permanent))
    #expect(results.first?.succeeded == false)
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("renamed/a").path))
    await destroy(index)
}

@Test func cancellationProducesPartialSnapshot() async throws {
    let f = try Fixture(); defer { f.dispose() }
    for i in 0..<600 { _ = try f.file("items/\(i)", bytes: 32) }
    let index = try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
    let coordinator = ScanCoordinator()
    let events = await coordinator.scan(ScanRequest(root: f.root), into: index)
    var final: ScanSnapshot?
    for await event in events {
        if case .progress = event { await coordinator.cancel() }
        if case .finished(let snapshot) = event { final = snapshot }
    }
    #expect(final?.cancelled == true)
    #expect(final?.complete == false)
    await destroy(index)
}
@Test func incompleteDirectoryRemainsUnknown() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let index = try f.index()
    try await index.insert([FileNode(id: 1, parentID: nil, path: f.root.path, name: "root", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "root"), FileNode(id: 2, parentID: 1, path: f.root.path + "/denied", name: "denied", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "denied")])
    await index.issue(path: f.root.path + "/denied", message: "Access denied")
    try await index.aggregate()
    #expect(await index.node(2)?.allocatedSize == nil)
    #expect(await index.node(1)?.allocatedSize == nil)
    await destroy(index)
}
@Test func cleanupReportsPartialFailures() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("keep"); _ = try f.file("remove")
    let (index, _) = try await scan(f.root)
    var q = FileQuery(); q.parentID = 1
    let nodes = await index.query(q)
    let keep = try #require(nodes.first { $0.name == "keep" }); let remove = try #require(nodes.first { $0.name == "remove" })
    try Data(repeating: 3, count: 128).write(to: keep.url)
    let ancestors = await index.ancestorIdentities(for: nodes.map(\.id))
    let results = await CleanupService().execute(CleanupPlan(root: f.root, items: [keep, remove], mode: .permanent, ancestorIdentities: ancestors))
    #expect(results.filter(\.succeeded).count == 1)
    #expect(FileManager.default.fileExists(atPath: keep.path))
    #expect(!FileManager.default.fileExists(atPath: remove.path))
    await destroy(index)
}

@Test func symbolicLinkCleanupNeverRemovesTarget() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let target = try f.file("target")
    let link = f.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let (index, _) = try await scan(f.root)
    let nodes = await index.query(FileQuery())
    let node = try #require(nodes.first { $0.name == "link" })
    let result = await CleanupService().execute(CleanupPlan(root: f.root, items: [node], mode: .permanent))
    #expect(result.first?.succeeded == true)
    #expect(FileManager.default.fileExists(atPath: target.path))
    await destroy(index)
}
@Test func restoredModificationDateDoesNotBypassFingerprint() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let url = try f.file("file")
    let (index, _) = try await scan(f.root)
    let node = try #require(await index.query(FileQuery()).first { $0.name == "file" })
    try Data(repeating: 4, count: 16384).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: try #require(node.modified)], ofItemAtPath: url.path)
    let result = await CleanupService().execute(CleanupPlan(root: f.root, items: [node], mode: .permanent))
    #expect(result.first?.succeeded == false)
    #expect(FileManager.default.fileExists(atPath: url.path))
    await destroy(index)
}
@Test func protectedLocationsCannotBeRemoved() {
    for path in ["/System/Library/test", "/Library/test", "/Applications/Example.app", "/Users/example/Library", "/Users/example/Library/Application Support", "/Users/example/Library/Containers/example/Data"] {
        let node = FileNode(id: 2, parentID: 1, path: path, name: "protected", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "test")
        #expect(CleanupSafety.blockedReason(node, root: URL(fileURLWithPath: "/")) != nil)
    }
}

@Test func searchMatchesCaseAndDiacritics() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("Résumé.txt")
    let (index, _) = try await scan(f.root)
    var query = FileQuery(); query.search = "RESUME"
    #expect(await index.query(query).first?.name == "Résumé.txt")
    await destroy(index)
}

@Test func scanRequestPreservesOriginalAuthorizationURL() {
    let original = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
    let request = ScanRequest(root: original)
    #expect(request.root == original)
    #expect(request.root.path == original.path)
}

@Test func mapAccountsForEntriesBeyondBrowserLimit() async throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let index = try fixture.index()
    let root = FileNode(id: 1, parentID: nil, path: "/map", name: "map", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "1")
    try await index.insert([root])
    for start in stride(from: 0, to: 3001, by: 512) {
        let nodes: [FileNode] = (start..<min(start+512,3001)).map { i in
            let logical = Int64(i+1); let allocated = logical * 4096
            return FileNode(id: Int64(i+2), parentID: 1, path: "/map/file-\(i).jpg", name: "file-\(i).jpg", isDirectory: false, logicalSize: logical, allocatedSize: allocated, modified: nil, identity: "\(i+2)") }
        try await index.insert(nodes)
    }
    try await index.aggregate()
    var query = FileQuery(); query.parentID = 1; query.limit = 250
    let firstPage = await index.query(query)
    query.offset = 250
    let secondPage = await index.query(query)
    #expect(Set(firstPage.map(\.id)).isDisjoint(with: secondPage.map(\.id)))
    let scene = await index.mapScene(rootID: 1, query: query, filtered: false)
    let allBytes = Int64(3001 * 3002 / 2) * 4096
    #expect(scene.summary.knownBytes == allBytes)
    #expect(scene.summary.itemCount == 3001)
    #expect(scene.entries.filter { $0.parentID == 1 }.reduce(0) { $0 + $1.bytes } == allBytes)
    let aggregate = try #require(scene.entries.first { $0.kind == .aggregate })
    #expect(aggregate.ownerID == 1 && aggregate.count == 3001 - 256)
    let bounded = await index.mapScene(rootID: 1, query: query, filtered: false, maxEntries: 6)
    #expect(bounded.entries.count <= 6)
    #expect(bounded.entries.reduce(0) { $0 + $1.bytes } == allBytes)
    await destroy(index)
}

@Test func nestedMapKeepsKnownBytesAndDeepestHitTargets() async throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    let index = try fixture.index()
    let nodes = [
        FileNode(id: 1,parentID: nil,path: "/map",name: "map",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "1"),
        FileNode(id: 2,parentID: 1,path: "/map/folder",name: "folder",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "2"),
        FileNode(id: 3,parentID: 2,path: "/map/folder/video.mov",name: "video.mov",isDirectory: false,logicalSize: 100,allocatedSize: 4096,modified: nil,identity: "3"),
        FileNode(id: 4,parentID: 2,path: "/map/folder/unknown",name: "unknown",isDirectory: false,logicalSize: nil,allocatedSize: nil,modified: nil,identity: "4")
    ]
    try await index.insert(nodes); try await index.aggregate()
    #expect(await index.node(2)?.allocatedSize == nil)
    #expect(await index.node(2)?.knownAllocatedSize == 4096)
    var query = FileQuery(); query.parentID = 1
    let scene = await index.mapScene(rootID: 1,query: query,filtered: false)
    #expect(scene.summary.knownBytes == 4096)
    #expect(scene.summary.unknownCount == 1)
    let tiles = NestedTreemap.layoutSync(scene,in: CGRect(x: 0,y: 0,width: 800,height: 500))
    let child = try #require(tiles.first { $0.id == 3 })
    let parent = try #require(tiles.first { $0.id == 2 })
    #expect(parent.isContainer)
    #expect(parent.rect.contains(child.rect))
    #expect(NestedTreemap.hitTest(CGPoint(x: child.rect.midX,y: child.rect.midY), tiles: tiles)?.id == 3)
    #expect(NestedTreemap.hitTest(CGPoint(x: parent.rect.midX,y: parent.rect.minY+8),tiles: tiles)?.id == 2)
    query.metric = .logical
    #expect(await index.mapScene(rootID: 1,query: query,filtered: false).summary.knownBytes == 100)
    await destroy(index)
}

@Test func mapFilteringHonorsSubtreeAndKeepsCategoriesStable() async throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    _ = try fixture.file("inside/photo.jpg"); _ = try fixture.file("outside/photo.jpg")
    let (index, _) = try await scan(fixture.root)
    var query = FileQuery(); query.leafResults = true; query.search = "photo"; query.subtreePath = fixture.root.appendingPathComponent("inside").path
    let scene = await index.mapScene(rootID: 1,query: query,filtered: true)
    #expect(scene.entries.count == 1)
    #expect(scene.entries.first?.category == .images)
    #expect(FileCategory.classify("example.MOV") == .video)
    #expect(FileCategory.classify("build.swift") == .development)
    #expect(FileCategory.classify("Unknown") == .other)
    await destroy(index)
}

@Test func cacheSuggestionsUseExplicitUserCacheRoot() async throws {
    let fixture = try Fixture(); defer { fixture.dispose() }
    _ = try fixture.file("user-caches/cache.bin"); _ = try fixture.file("other/cache.bin")
    let (index, _) = try await scan(fixture.root)
    var query = FileQuery(); query.suggestion = .caches
    query.cacheRootPath = fixture.root.appendingPathComponent("user-caches").path
    let rows = await index.query(query)
    #expect(rows.count == 1)
    #expect(rows.first?.path.hasPrefix(query.cacheRootPath! + "/") == true)
    await destroy(index)
}

@Test func transactionalBranchRefreshPreservesIDsAndReassignsHardLinks() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let original = try f.file("branch/original.bin", bytes: 1024)
    try FileManager.default.linkItem(at: original, to: f.root.appendingPathComponent("alias.bin"))
    _ = try f.file("unaffected/keep.txt", bytes: 77)
    let (index, _) = try await scan(f.root)
    let branch = try #require(await index.node(path: f.root.path + "/branch"))
    let keep = try #require(await index.node(path: f.root.path + "/unaffected/keep.txt"))
    let alias = try #require(await index.node(path: f.root.path + "/alias.bin"))
    try FileManager.default.removeItem(at: original)
    _ = try f.file("branch/new.txt", bytes: 200)
    let (staging, _) = try await scan(branch.url)
    await staging.close()
    let revision = await index.revision
    _ = try await index.replaceBranch(BranchRefreshRequest(nodeID: branch.id, identity: branch.identity), stagingURL: staging.url)
    #expect(await index.revision == revision + 1)
    #expect(await index.node(branch.id)?.identity == branch.identity)
    #expect(await index.node(keep.id)?.path == keep.path)
    #expect(await index.node(alias.id)?.logicalSize == 1024)
    #expect(await index.node(1)?.logicalSize == 1301)
    #expect(await index.node(path: original.path) == nil)
    let inserted = try #require(await index.node(path: branch.path + "/new.txt"))
    #expect(inserted.id > max(keep.id,alias.id))
    await destroy(staging); await destroy(index)
}

@Test func refreshRejectsReplacedRootWithoutChangingIndex() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("branch/a", bytes: 10)
    let (index, _) = try await scan(f.root)
    let branch = try #require(await index.node(path: f.root.path + "/branch"))
    let (staging, _) = try await scan(branch.url); await staging.close()
    try FileManager.default.moveItem(at: branch.url, to: f.root.appendingPathComponent("old"))
    try FileManager.default.createDirectory(at: branch.url, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await index.replaceBranch(BranchRefreshRequest(nodeID: branch.id, identity: branch.identity), stagingURL: staging.url) }
    #expect(await index.node(branch.id)?.logicalSize == 10)
    await destroy(staging); await destroy(index)
}

@Test func categoryStatisticsCoverFullScopeBeyondMapBudget() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let index = try f.index()
    let root = FileNode(id: 1,parentID: nil,path: "/stats",name: "stats",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "root")
    try await index.insert([root])
    for batch in 0..<6 {
        let nodes = (0..<500).map { i in
            let id = Int64(batch*500+i+2)
            return FileNode(id: id,parentID: 1,path: "/stats/\(id).mp4",name: "\(id).mp4",isDirectory: false,logicalSize: 10,allocatedSize: i == 0 ? nil : 20,modified: nil,identity: "\(id)")
        }
        try await index.insert(nodes)
    }
    try await index.aggregate()
    var q = FileQuery(); q.subtreePath = "/stats"
    let stats = await index.categorySummaries(q)
    #expect(stats.count == 1)
    #expect(stats.first?.count == 3000)
    #expect(stats.first?.unknown == 6)
    #expect((stats.first?.bytes ?? -1) == Int64(59_880))
    q.leafResults = true; q.knownSizesOnly = true; q.limit = 250
    #expect(await index.query(q).count == 250)
    #expect(await index.summary(q).itemCount == 2994)
    await destroy(index)
}

@Test func curatedCacheRulesUseDescendantAgeAndExclusions() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let index = try f.index()
    let home = "/Users/rules"; let root = home + "/Library/Caches"
    let old = Date().addingTimeInterval(-90*86400)
    func node(_ id: Int64,_ parent: Int64?,_ path: String,_ directory: Bool,_ date: Date?) -> FileNode {
        FileNode(id: id,parentID: parent,path: path,name: URL(fileURLWithPath: path).lastPathComponent,isDirectory: directory,logicalSize: 10,allocatedSize: 10,modified: date,identity: "\(id)")
    }
    try await index.insert([node(1,nil,root,true,old), node(2,1,root+"/old",true,old),node(3,2,root+"/old/a",false,old),node(4,1,root+"/recent",true,old),node(5,4,root+"/recent/a",false,Date()),node(6,1,root+"/unknown",false,nil)])
    try await index.aggregate()
    var q = FileQuery(); q.cleanupRule = .userCaches; q.userHome = home; q.leafResults = true
    #expect(await index.query(q).map(\.id) == [2])
    q.excludedCandidatePaths = [root + "/old"]
    #expect(await index.query(q).isEmpty)
    await destroy(index)
}

@Test func refreshedSameIdentityKeepsIDAndReplacementsNeverReuseIDs() async throws {
    let f = try Fixture(); defer { f.dispose() }
    let keptURL = try f.file("branch/keep",bytes: 50)
    let removedURL = try f.file("branch/removed",bytes: 51)
    let (index, _) = try await scan(f.root)
    let branch = try #require(await index.node(path: f.root.path+"/branch"))
    let kept = try #require(await index.node(path: keptURL.path))
    let removed = try #require(await index.node(path: removedURL.path))
    // Preserve the old inode elsewhere so the filesystem cannot recycle it for the replacement.
    try FileManager.default.moveItem(at: removedURL,to: f.root.appendingPathComponent("old-inode"))
    _ = try f.file("branch/removed",bytes: 60)
    let (first, _) = try await scan(branch.url); await first.close()
    _ = try await index.replaceBranch(BranchRefreshRequest(nodeID: branch.id,identity: branch.identity),stagingURL: first.url)
    #expect(await index.node(path: keptURL.path)?.id == kept.id)
    let replacement = try #require(await index.node(path: removedURL.path))
    #expect(replacement.id != removed.id)
    try FileManager.default.removeItem(at: removedURL)
    let (second, _) = try await scan(branch.url); await second.close()
    _ = try await index.replaceBranch(BranchRefreshRequest(nodeID: branch.id,identity: branch.identity),stagingURL: second.url)
    _ = try f.file("branch/another",bytes: 70)
    let (third, _) = try await scan(branch.url); await third.close()
    _ = try await index.replaceBranch(BranchRefreshRequest(nodeID: branch.id,identity: branch.identity),stagingURL: third.url)
    #expect(await index.node(path: branch.path+"/another")!.id > replacement.id)
    await destroy(first); await destroy(second); await destroy(third); await destroy(index)
}

@Test func partialRefreshReplacesStaleChildrenWithExplicitUnknownSize() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("branch/a",bytes: 100)
    let (index, _) = try await scan(f.root)
    let branch = try #require(await index.node(path: f.root.path+"/branch"))
    let staging = try ScanIndex(url: f.root.appendingPathComponent("staging.sqlite"))
    try await staging.insert([FileNode(id: 1,parentID: nil,path: branch.path,name: branch.name,isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: branch.modified,identity: branch.identity)])
    await staging.issue(path: branch.path,message: "Fixture denial")
    try await staging.aggregate(); await staging.close()
    _ = try await index.replaceBranch(BranchRefreshRequest(nodeID: branch.id,identity: branch.identity),stagingURL: staging.url)
    #expect(await index.node(path: branch.path+"/a") == nil)
    #expect(await index.node(branch.id)?.allocatedSize == nil)
    #expect(await index.node(1)?.unknownAllocatedCount == 1)
    var q = FileQuery(); q.subtreePath = f.root.path
    let stats = await index.categorySummaries(q)
    #expect(stats.first?.unknown == 1)
    await destroy(staging); await destroy(index)
}

@Test func cleanupPreflightIsRecheckedForEverySerialItem() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("a"); _ = try f.file("b")
    let (index, _) = try await scan(f.root)
    var q = FileQuery(); q.parentID = 1
    let nodes = await index.query(q)
    let gate = CleanupGate()
    let results = await CleanupService().execute(CleanupPlan(root: f.root,items: nodes,mode: .permanent,preflight: { _ in await gate.reason() }))
    #expect(results.count == 2)
    #expect(results.allSatisfy { !$0.succeeded })
    #expect(await gate.calls == 2)
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("a").path))
    await destroy(index)
}
private actor CleanupGate {
    private(set) var calls = 0
    func reason() -> String? { calls += 1; return "Fixture activity changed" }
}

@Test func selectedSymbolicLinkRootIsNotFollowed() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("target/payload")
    let link = f.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link,withDestinationURL: f.root.appendingPathComponent("target"))
    let (index, snapshot) = try await scan(link)
    #expect(await index.node(1) == nil)
    #expect(snapshot?.complete == false)
    await destroy(index)
}

@Test func packageInteriorRefreshRetainsCleanupProtection() async throws {
    let f = try Fixture(); defer { f.dispose() }
    _ = try f.file("Example.app/Contents/a",bytes: 10)
    let (index, _) = try await scan(f.root)
    let branch = try #require(await index.node(path: f.root.path+"/Example.app/Contents"))
    #expect(branch.packageAncestor)
    _ = try f.file("Example.app/Contents/new",bytes: 20)
    let (staging, _) = try await scan(branch.url); await staging.close()
    _ = try await index.replaceBranch(BranchRefreshRequest(nodeID: branch.id,identity: branch.identity),stagingURL: staging.url)
    let new = try #require(await index.node(path: branch.path+"/new"))
    #expect(new.packageAncestor)
    #expect(CleanupSafety.blockedReasonCode(new,root: f.root) == .packageContents)
    await destroy(staging); await destroy(index)
}
