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
