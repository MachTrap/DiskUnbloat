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
        for folder in ["Desktop", "Documents", "Library/Containers/com.example.app/Data", "Library/Application Support/Example",
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

    @Test func minimalPolicyProbesOnlyTheAppDataConsent() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let canonical = canonicalURL(home).path
        let minimal = ScanPermissionPreflight.targets(for: request(home, .minimal)).map(\.url.path)
        #expect(minimal == [canonical + "/Library/Containers", canonical + "/Library/Application Support"])
        // The full policy still brings every in-scope dialog up front.
        let full = ScanPermissionPreflight.targets(for: request(home, .fullDiskAccess)).map(\.url.path)
        #expect(full.contains(canonical + "/Desktop") && full.contains(canonical + "/Library/Mail"))
        #expect(ScanPermissionPreflight.skippedPaths(for: request(home, .fullDiskAccess)).isEmpty)
        #expect(Set(ScanPermissionPreflight.skippedPaths(for: request(home, .minimal)))
            == [canonical + "/Pictures/Photos Library.photoslibrary", canonical + "/Library/Mail"])
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
        #expect(probed.withLock { $0 } == ["Containers", "Application Support"])
        #expect(refused)
        let canonical = canonicalURL(home).path
        // The store itself is listed with an honest issue, but nothing inside was read.
        #expect(await index.node(path: canonical + "/Pictures/Photos Library.photoslibrary") != nil)
        #expect(await index.node(path: canonical + "/Pictures/Photos Library.photoslibrary/originals") == nil)
        #expect(await index.node(path: canonical + "/Library/Mail/V10") == nil)
        #expect(await index.node(path: canonical + "/Documents/notes.txt") != nil)
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
