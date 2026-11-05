import CryptoKit
import Darwin
import Foundation

/// Which copy of an identical set is kept. The rest are offered for removal.
public enum DuplicateKeepStrategy: String, CaseIterable, Sendable, Identifiable {
    /// The earliest-modified copy, usually the original. Ties keep the shortest path.
    case oldest
    /// The most recently modified copy.
    case newest
    /// The copy closest to the top of the folder tree.
    case shortestPath
    public var id: Self { self }
}

/// Files with byte-identical contents (same size, same SHA-256), one per inode.
public struct DuplicateSet: Sendable, Equatable {
    public let files: [FileNode]
    public init(files: [FileNode]) { self.files = files.sorted { $0.path < $1.path } }
    public var size: Int64 { files.first?.knownSize(for: .allocated) ?? 0 }

    public func keeper(_ strategy: DuplicateKeepStrategy) -> FileNode {
        func depth(_ node: FileNode) -> Int { node.path.split(separator: "/").count }
        func shorter(_ a: FileNode, _ b: FileNode) -> Bool {
            (depth(a), a.path.count, a.path) < (depth(b), b.path.count, b.path)
        }
        let date: (FileNode) -> Double = { $0.modified?.timeIntervalSince1970 ?? .infinity }
        switch strategy {
        case .oldest: return files.min { date($0) != date($1) ? date($0) < date($1) : shorter($0, $1) }!
        case .newest: return files.min { date($0) != date($1) ? date($0) > date($1) : shorter($0, $1) }!
        case .shortestPath: return files.min(by: shorter)!
        }
    }
    public func copies(_ strategy: DuplicateKeepStrategy) -> [FileNode] {
        let kept = keeper(strategy)
        return files.filter { $0.id != kept.id }
    }
}

public struct DuplicateSearch: Sendable, Equatable {
    public let sets: [DuplicateSet]
    /// Candidates whose contents could not be read (permissions, placeholders, changes).
    public let unreadable: Int
    public init(sets: [DuplicateSet], unreadable: Int) { self.sets = sets; self.unreadable = unreadable }

    /// Every copy except the kept one per set, as a quick-select result; each group's
    /// location is the kept copy, which cleanup re-verifies before removing anything.
    public func result(_ strategy: DuplicateKeepStrategy) -> AutoSelectionResult {
        AutoSelectionResult(groups: sets.map { set in
            AutoSelectionGroup(location: set.keeper(strategy), nodes: set.copies(strategy), coversAllChildren: false)
        })
    }
    public var reclaimableBytes: Int64 { sets.reduce(0) { $0 + $1.size * Int64($1.files.count - 1) } }
    public var copyCount: Int { sets.reduce(0) { $0 + $1.files.count - 1 } }
}

/// Finds identical files among the scanned ones. Unlike scanning, this reads file
/// contents, so it only runs when the user asks. Two passes keep it cheap: a hash of the
/// first 64 KB, then a full hash only for files whose prefixes still collide. iCloud
/// placeholders are skipped (never downloaded) and links are never followed.
public enum DuplicateFinder {
    public static let defaultMinimumSize: Int64 = 1 << 20
    static let prefixBytes = 64 * 1024

    public static func find(
        in index: ScanIndex, minimumSize: Int64 = defaultMinimumSize,
        eligible: @escaping @Sendable (FileNode) -> Bool = { _ in true },
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> DuplicateSearch {
        let groups = await index.duplicateCandidates(minimumSize: minimumSize)
            .map { $0.filter(eligible) }.filter { $0.count > 1 }
        return try await Task.detached(priority: .userInitiated) {
            try search(groups, progress: progress)
        }.value
    }

    static func search(_ groups: [[FileNode]], progress: (Int, Int) -> Void) throws -> DuplicateSearch {
        let total = groups.reduce(0) { $0 + $1.count }
        var done = 0, unreadable = 0
        var sets: [DuplicateSet] = []
        for group in groups {
            try Task.checkCancellation()
            var byPrefix: [SHA256Digest: [FileNode]] = [:]
            for file in group {
                if let digest = digest(file.path, limit: prefixBytes) { byPrefix[digest, default: []].append(file) } else { unreadable += 1 }
                done += 1
                if done % 16 == 0 { progress(done, total) }
            }
            for collided in byPrefix.values where collided.count > 1 {
                // Files no larger than the prefix are already fully compared.
                if (collided[0].logicalSize ?? 0) <= Int64(prefixBytes) { sets.append(DuplicateSet(files: collided)); continue }
                var byContent: [SHA256Digest: [FileNode]] = [:]
                for file in collided {
                    try Task.checkCancellation()
                    if let digest = digest(file.path, limit: nil) { byContent[digest, default: []].append(file) } else { unreadable += 1 }
                }
                sets += byContent.values.filter { $0.count > 1 }.map(DuplicateSet.init)
            }
        }
        progress(total, total)
        return DuplicateSearch(sets: sets.sorted { $0.size * Int64($0.files.count - 1) > $1.size * Int64($1.files.count - 1) }, unreadable: unreadable)
    }

    /// SHA-256 of a regular file's first `limit` bytes (all when `nil`), or `nil` when it
    /// is not a plain local file or cannot be read.
    static func digest(_ path: String, limit: Int?) -> SHA256Digest? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        // SF_DATALESS: an iCloud placeholder; reading it would download it.
        guard info.st_flags & 0x4000_0000 == 0 else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min(chunk, remaining)) }
            if count < 0 { return nil }
            if count == 0 { break }
            hasher.update(data: buffer[0..<count])
            remaining -= count
        }
        return hasher.finalize()
    }
}

extension ScanIndex {
    /// Same-size regular files outside packages, at least `minimumSize`, grouped by size;
    /// hard links collapse to one entry per inode so they never count as duplicates.
    public func duplicateCandidates(minimumSize: Int64) -> [[FileNode]] {
        let floor = max(1, minimumSize)
        let files = read("""
            SELECT * FROM nodes WHERE directory=0 AND symlink=0 AND insidePackage=0 AND summary=0 AND incomplete=0
              AND logical>=\(floor) AND logical IN (
                SELECT logical FROM nodes WHERE directory=0 AND symlink=0 AND insidePackage=0 AND summary=0 AND logical>=\(floor)
                GROUP BY logical HAVING COUNT(DISTINCT identity)>1)
            ORDER BY logical DESC, path
            """)
        var groups: [Int64: [FileNode]] = [:]; var order: [Int64] = []
        var seen: Set<String> = []
        for file in files {
            guard let size = file.logicalSize, seen.insert(file.identity).inserted else { continue }
            if groups[size] == nil { order.append(size) }
            groups[size, default: []].append(file)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }
}
