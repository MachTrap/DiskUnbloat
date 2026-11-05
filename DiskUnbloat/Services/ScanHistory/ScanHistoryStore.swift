import CryptoKit
import Foundation
import DiskCore

/// Keeps the last few scan snapshots per scope in Application Support, for growth
/// comparisons. Local only; the user can turn it off or clear it in Settings.
struct ScanHistoryStore: Sendable {
    let base: URL
    let keep: Int

    init(base: URL? = nil, keep: Int = 10) {
        // Hosted unit tests build workspaces with default settings; their scans must never
        // land in the user's real history.
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.base = base ?? (underTests
            ? FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloatTests-History-\(getpid())", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DiskUnbloat/History", isDirectory: true))
        self.keep = keep
    }

    private func folder(_ rootKey: String) -> URL {
        let digest = SHA256.hash(data: Data(rootKey.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent(digest, isDirectory: true)
    }

    /// Saved scans of this scope, newest first.
    func dates(rootKey: String) -> [Date] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(rootKey), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { Double($0.deletingPathExtension().lastPathComponent).map(Date.init(timeIntervalSince1970:)) }.sorted(by: >)
    }

    func load(rootKey: String, date: Date) -> ScanHistorySnapshot? {
        let url = folder(rootKey).appendingPathComponent(String(Int64(date.timeIntervalSince1970)) + ".json")
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(ScanHistorySnapshot.self, from: data),
              snapshot.rootKey == rootKey else { return nil }
        return snapshot
    }

    func save(_ snapshot: ScanHistorySnapshot) throws {
        let directory = folder(snapshot.rootKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(String(Int64(snapshot.date.timeIntervalSince1970)) + ".json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        for old in dates(rootKey: snapshot.rootKey).dropFirst(keep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(String(Int64(old.timeIntervalSince1970)) + ".json"))
        }
    }

    func clear() { try? FileManager.default.removeItem(at: base) }
}
