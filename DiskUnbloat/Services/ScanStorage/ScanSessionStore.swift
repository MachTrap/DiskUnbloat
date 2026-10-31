import Foundation
import Darwin
import DiskCore

/// Each live process/session owns its own directory; startup never unlinks another running scan.
struct ScanSessionStore {
    private let base: URL
    private let directory: URL

    init() {
        base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
        directory = base.appendingPathComponent(String(getpid()), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func purgeAbandonedIndexes() {
        for processDirectory in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            guard let pid = Int32(processDirectory.lastPathComponent), pid > 0 else { continue }
            // EPERM means a process may exist but cannot be inspected: retain its files.
            if kill(pid, 0) == -1 && errno == ESRCH { try? FileManager.default.removeItem(at: processDirectory) }
        }
    }

    func makeIndex() throws -> ScanIndex {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ScanIndex(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
    }

    func discard(_ index: ScanIndex) async {
        await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: index.url.path + suffix) }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try? FileManager.default.removeItem(at: directory) }
    }
}
