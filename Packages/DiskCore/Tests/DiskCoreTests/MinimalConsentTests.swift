import Foundation
import Synchronization
import Testing
@testable import DiskCore

/// Without Full Disk Access the scan may ask macOS for exactly one consent (other
/// applications' data); personal-data stores are skipped unopened and reported, so no
/// further dialog can appear during enumeration.
struct MinimalConsentTests {
    private func home() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("minimal-" + UUID().uuidString)
        for folder in ["Desktop", "Documents", "Library/Containers/com.example.editor/Data", "Library/Containers/com.apple.Music/Data", "Library/Containers/com.apple.AMPArtworkAgent/Data", "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/x", "Library/Application Support/Example", "Movies/iMovie Theater.theater/Content", "Movies/iMovie Library.imovielibrary/Media", "Elsewhere/Old.photoslibrary/originals",
                       "Pictures/Photos Library.photoslibrary/originals", "Library/Mail/V10", "Library/Caches/com.example"] {
            try fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(count: 8192).write(to: home.appendingPathComponent("Pictures/Photos Library.photoslibrary/originals/IMG.heic"))
        try Data(count: 4096).write(to: home.appendingPathComponent("Library/Mail/V10/mail.emlx"))
        try Data(count: 4096).write(to: home.appendingPathComponent("Documents/notes.txt"))
        return URL(fileURLWithPath: home.path).resolvingSymlinksInPath().standardizedFileURL
    }
    private func request(_ home: URL, _ policy: ConsentPolicy) -> ScanRequest {
        var options = ScanOptions(); options.consentPolicy = policy; options.homePaths = [canonicalURL(home).path]
        return ScanRequest(root: home, options: options)
    }

    @Test func minimalPolicyAsksMediaThenAppDataUpFront() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let canonical = canonicalURL(home).path
        let minimal = ScanPermissionPreflight.targets(for: request(home, .minimal)).map(\.url.path)
        // Photos first, then the app-data probes (no Music/TV library in this fixture).
        #expect(minimal == [canonical + "/Pictures/Photos Library.photoslibrary", canonical + "/Library/Containers", canonical + "/Library/Application Support"])
        // The full policy still brings every in-scope dialog up front.
        let full = ScanPermissionPreflight.targets(for: request(home, .fullDiskAccess)).map(\.url.path)
        #expect(full.contains(canonical + "/Desktop") && full.contains(canonical + "/Library/Mail"))
        #expect(ScanPermissionPreflight.skippedPaths(for: request(home, .fullDiskAccess)).isEmpty)
        // Lexical, never stat-ed: every store under the home, whether or not it exists.
        let skipped = Set(ScanPermissionPreflight.skippedPaths(for: request(home, .minimal)))
        #expect(skipped.isSuperset(of: [canonical + "/Library/Mail", canonical + "/Library/Containers/com.apple.mail"]))
        // Media libraries, iCloud Drive, Safari and Apple app containers are read, never skipped.
        for kept in ["/Pictures/Photos Library.photoslibrary", "/Movies/TV", "/Library/Mobile Documents", "/Library/Safari", "/Library/Containers/com.apple.Music"] {
            #expect(!skipped.contains(canonical + kept), "\(kept)")
        }
        #expect(skipped.count == ScanPermissionPreflight.minimalSkippedRelativePaths.count)
        // The app-data probes only ever open third-party children; media probes come first.
        #expect(ScanPermissionPreflight.minimalConsentTargets.filter { $0.path == "Library/Containers" || $0.path == "Library/Application Support" }.allSatisfy { $0.depth == .thirdPartyChildren })
        #expect(ScanPermissionPreflight.minimalConsentTargets.prefix(4).map(\.path) == ["Pictures/Photos Library.photoslibrary", "Music/Music", "Movies/TV", "Library/Mobile Documents"])
    }

    @Test func minimalScanSkipsPersonalStoresUnopenedAndExplainsOnce() async throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let probed = Mutex<[String]>([])
        let coordinator = ScanCoordinator(preflightProbe: { target, _ in probed.withLock { $0.append(target.url.lastPathComponent) }; return .readable })
        let index = try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        var refused = false
        for await event in await coordinator.scan(request(home, .minimal), into: index) {
            if case .protectedFoldersRefused = event { refused = true }
        }
        #expect(probed.withLock { $0 } == ["Photos Library.photoslibrary", "Containers", "Application Support"])
        #expect(refused)
        let canonical = canonicalURL(home).path
        // Media libraries are measured (their consent was asked up front)…
        #expect(await index.node(path: canonical + "/Pictures/Photos Library.photoslibrary") != nil)
        // …while Mail is listed with an honest issue and nothing inside it is read.
        #expect(await index.node(path: canonical + "/Library/Mail/V10") == nil)
        #expect(await index.node(path: canonical + "/Documents/notes.txt") != nil)
        // Apple and third-party app containers are both read (macOS decides what it refuses).
        #expect(await index.node(path: canonical + "/Library/Containers/com.apple.AMPArtworkAgent/Data") != nil)
        #expect(await index.node(path: canonical + "/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/x") != nil)
        #expect(await index.node(path: canonical + "/Library/Containers/com.example.editor/Data") != nil)
        // Other media libraries are measured like any package (sized whole, contents not listed).
        let theater = await index.node(path: canonical + "/Movies/iMovie Theater.theater")
        #expect(theater != nil && theater?.unknownAllocatedCount == 0)
        let issues = await index.issues().map(\.path)
        #expect(issues.contains(canonical + "/Library/Mail"))
        await index.close()
    }
}

/// The unreached-space tile is laid out beside the root's children when it is big
/// enough to see, and never folded into an "N more items" aggregate.
struct UnreachedTileLayoutTests {
    private func file(_ id: Int64, _ bytes: Int64) -> MapEntry {
        MapEntry(id: id, parentID: 1, ownerID: 1, kind: .file, node: FileNode(id: id, parentID: 1, path: "/v/\(id)", name: "\(id)", isDirectory: false, logicalSize: bytes, allocatedSize: bytes, modified: nil, identity: "\(id)"), bytes: bytes)
    }
    @Test func unreachedTileStandsAloneOrDisappears() {
        let unreached = MapEntry(id: MapEntry.unreachedID, parentID: 1, ownerID: 1, kind: .unreached, node: nil, bytes: 600)
        let big = NestedTreemap.layoutSync(MapScene(rootID: 1, entries: [file(2, 400), unreached]), in: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(big.contains { $0.entry.kind == .unreached && $0.id == MapEntry.unreachedID })
        #expect(!big.contains { $0.entry.kind == .aggregate })
        let tiny = MapEntry(id: MapEntry.unreachedID, parentID: 1, ownerID: 1, kind: .unreached, node: nil, bytes: 1)
        let small = NestedTreemap.layoutSync(MapScene(rootID: 1, entries: [file(2, 10_000_000), tiny]), in: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(!small.contains { $0.entry.kind == .unreached || $0.entry.kind == .aggregate })
    }
}

/// Careful listing (used where a protected store sits) must describe every other entry
/// exactly like the bulk reader, and never request the skipped entry's attributes.
struct CarefulListingTests {
    @Test func carefulEntriesMatchBulkEntriesAndSkipStaysBare() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("careful-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("TV/inner"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Clips"), withIntermediateDirectories: true)
        try Data(count: 12_345).write(to: root.appendingPathComponent("movie.mp4"))
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = BulkDirectoryReader()
        var bulk: [String: BulkEntry] = [:], careful: [String: BulkEntry] = [:]
        try reader.read(root.path) { bulk[$0.name] = $0 }
        try reader.readCarefully(root.path, skip: { name, _ in name == "TV" }) { careful[$0.name] = $0 }
        #expect(Set(careful.keys) == Set(bulk.keys))
        for name in ["movie.mp4", "Clips"] {
            let a = try #require(bulk[name]), b = try #require(careful[name])
            #expect(a.identity == b.identity && a.fingerprint == b.fingerprint && a.size == b.size && a.allocated == b.allocated && a.kind == b.kind)
        }
        let tv = try #require(careful["TV"])
        #expect(tv.kind == .directory && tv.size == 0 && tv.modified.tv_sec == 0)
    }
}
