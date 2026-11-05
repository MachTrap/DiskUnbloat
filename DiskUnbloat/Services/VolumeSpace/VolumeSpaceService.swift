import Foundation
import Darwin

/// Space on a scanned volume that the scan itself did not account for. Approximate by
/// nature: the volume's used space (as Finder reports it) minus the bytes the scan read.
struct UnreachedSpace: Equatable, Sendable {
    let bytes: Int64
    /// Space macOS can reclaim on its own (caches, purgeable files), when reported.
    let purgeable: Int64?
    /// Local APFS snapshots (Time Machine and updates); their size is not reported.
    let localSnapshots: Int?
    /// Locations the scan recorded as unreadable.
    let unreadableLocations: Int
}

/// App-only OS adapter for volume facts. Read-only: it never thins or deletes snapshots.
enum VolumeSpaceService {
    /// Whether `url` is the mount point of a volume (including `/`).
    static func isVolumeRoot(_ url: URL) -> Bool {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return false }
        let mount = withUnsafeBytes(of: &stats.f_mntonname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return canonicalPath(url) == mount
    }

    /// Used space as Finder shows it: total minus available. On APFS this covers the
    /// whole container's share for the volume group, unlike `statfs` on the sealed `/`.
    static func usedBytes(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        let used = Int64(total) - Int64(available)
        return used > 0 ? used : nil
    }

    static func purgeableBytes(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let important = values.volumeAvailableCapacityForImportantUsage, let available = values.volumeAvailableCapacity else { return nil }
        let purgeable = important - Int64(available)
        return purgeable > 0 ? purgeable : nil
    }

    /// Counts local snapshots with `tmutil listlocalsnapshots` (read-only, no privileges).
    static func localSnapshotCount(_ url: URL) async -> Int? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
            process.arguments = ["listlocalsnapshots", url.path]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate(); return nil }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return output.split(separator: "\n").filter { $0.contains("com.apple") }.count
        }.value
    }

    /// Unreached space for a finished scan of a volume root, or `nil` when the root is
    /// not a volume or nothing is missing.
    static func unreached(root: URL, knownBytes: Int64, unreadableLocations: Int) async -> UnreachedSpace? {
        guard isVolumeRoot(root), let used = usedBytes(root), used > knownBytes else { return nil }
        return UnreachedSpace(bytes: used - knownBytes, purgeable: purgeableBytes(root),
                              localSnapshots: await localSnapshotCount(root), unreadableLocations: unreadableLocations)
    }

    private static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
