import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Which copy of an identical set is kept. The rest are offered for removal.
public enum DuplicateKeepStrategy: String, CaseIterable, Sendable, Identifiable {
    case oldest
    case newest
    case shortestPath
    public var id: Self { self }

    func keeper(in nodes: [FileNode]) -> FileNode {
        func shorter(_ a: FileNode, _ b: FileNode) -> Bool {
            let depthA = a.path.split(separator: "/").count
            let depthB = b.path.split(separator: "/").count
            if depthA != depthB { return depthA < depthB }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
        }
        return nodes.min { a, b in
            if self != .shortestPath {
                switch (a.modified, b.modified) {
                case let (left?, right?) where left != right:
                    return self == .oldest ? left < right : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return shorter(a, b)
        }!
    }
}

/// Files with byte-identical data (same size, same SHA-256), one per inode.
public struct DuplicateSet: Sendable, Equatable, Identifiable {
    public let files: [FileNode]
    public let relatedFolderIDs: [Int64]
    public var id: Int64 { files[0].id }
    public var size: Int64 { files.first?.knownSize(for: .allocated) ?? 0 }

    public init(files: [FileNode], relatedFolderIDs: [Int64] = []) {
        self.files = files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        self.relatedFolderIDs = relatedFolderIDs
    }

    public func keeper(_ strategy: DuplicateKeepStrategy) -> FileNode { strategy.keeper(in: files) }
    public func copies(_ strategy: DuplicateKeepStrategy) -> [FileNode] {
        let kept = keeper(strategy)
        return files.filter { $0.id != kept.id }
    }

    var offeredBytes: Int64 {
        files.reduce(0) { $0 + $1.knownAllocatedSize } - (files.map(\.knownAllocatedSize).min() ?? 0)
    }
}

public struct DuplicateSearch: Sendable, Equatable {
    /// File matches that are not wholly represented by one matching folder comparison.
    public let sets: [DuplicateSet]
    public let folderSets: [DuplicateFolderSet]
    /// Unique indexed candidates whose data could not be compared.
    public let unreadable: Int
    public let folderLimitExceeded: Bool
    public let revision: UInt64

    public init(sets: [DuplicateSet], unreadable: Int, folderSets: [DuplicateFolderSet] = [], folderLimitExceeded: Bool = false, revision: UInt64 = 0) {
        self.sets = sets
        self.unreadable = unreadable
        self.folderSets = folderSets
        self.folderLimitExceeded = folderLimitExceeded
        self.revision = revision
    }

    public var reclaimableBytes: Int64 { sets.reduce(0) { $0 + $1.offeredBytes } }
    public var copyCount: Int { sets.reduce(0) { $0 + $1.files.count - 1 } }

    /// The original file-only automatic selection. Explicit review builds its own pairs.
    public func result(_ strategy: DuplicateKeepStrategy) -> AutoSelectionResult {
        AutoSelectionResult(groups: sets.map { set in
            AutoSelectionGroup(location: set.keeper(strategy), nodes: set.copies(strategy), coversAllChildren: false)
        })
    }
}

public struct DuplicateProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case comparingFiles, verifyingFolders }
    public let stage: Stage
    public let completed: Int
    /// A real number of work items when known. An unknown total is indeterminate.
    public let total: Int?

    public init(stage: Stage, completed: Int, total: Int?) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }
}

public enum DuplicateSearchError: Error { case staleIndex }

struct DuplicateCandidate: Sendable {
    let node: FileNode
    /// Raw logical bytes. An indexed hard-link alias may carry zero *counted* bytes.
    let size: Int64
}

/// Content is read only here, on explicit request. First compare 64 KiB, then read
/// the full data of prefix collisions and files in a candidate folder comparison.
public enum DuplicateFinder {
    public static let defaultMinimumSize: Int64 = 1 << 20
    static let prefixBytes = 64 * 1024
    static let defaultFolderEntryLimit = 20_000

    @concurrent public static func find(
        in index: ScanIndex, minimumSize: Int64 = defaultMinimumSize,
        eligible: @escaping @Sendable (FileNode) -> Bool = { _ in true },
        progress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }
    ) async throws -> DuplicateSearch {
        try await find(in: index, minimumSize: minimumSize, folderEntryLimit: defaultFolderEntryLimit, eligible: eligible, progress: progress)
    }

    @concurrent static func find(
        in index: ScanIndex, minimumSize: Int64, folderEntryLimit: Int,
        eligible: @escaping @Sendable (FileNode) -> Bool = { _ in true },
        progress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }
    ) async throws -> DuplicateSearch {
        progress(.init(stage: .comparingFiles, completed: 0, total: nil))
        let snapshot = try await index.duplicateCandidateSnapshot(minimumSize: minimumSize, eligible: eligible)
        let compared = try await DuplicateIO.run { cancellation in
            try compare(snapshot.groups, progress: progress, checkCancellation: cancellation.check)
        }
        try await index.validateDuplicateRevision(snapshot.revision)
        let folders = try await DuplicateFolderMatcher.match(
            compared.sets, index: index, revision: snapshot.revision, entryLimit: folderEntryLimit,
            eligible: eligible, observations: compared.observations, progress: progress
        )
        try await index.validateDuplicateRevision(snapshot.revision)
        return DuplicateSearch(
            sets: folders.files, unreadable: compared.unreadable.union(folders.unreadable).count,
            folderSets: folders.sets, folderLimitExceeded: folders.limitExceeded, revision: snapshot.revision
        )
    }

    struct Comparison: Sendable {
        var sets: [DuplicateSet] = []
        var unreadable: Set<Int64> = []
        var observations: [Int64: DuplicateIO.Observation] = [:]
    }

    static func compare(
        _ groups: [[DuplicateCandidate]], progress: @escaping (DuplicateProgress) -> Void,
        checkCancellation: () throws -> Void
    ) throws -> Comparison {
        var output = Comparison()
        var buffer = [UInt8](repeating: 0, count: DuplicateIO.chunkSize)
        var report = DuplicateProgressReporter(stage: .comparingFiles, send: progress)
        let total = groups.reduce(0) { $0 + $1.count }
        var completed = 0
        for group in groups {
            try checkCancellation()
            var byPrefix: [SHA256Digest: [DuplicateCandidate]] = [:]
            for candidate in group {
                let observation = try DuplicateIO.read(candidate, limit: prefixBytes, buffer: &buffer, checkCancellation: checkCancellation)
                guard let observation else {
                    output.unreadable.insert(candidate.node.id)
                    completed += 1
                    report.update(completed: completed, total: total)
                    continue
                }
                byPrefix[observation.digest, default: []].append(candidate)
                if candidate.size <= prefixBytes { output.observations[candidate.node.id] = observation }
            }
            for matches in byPrefix.values {
                try checkCancellation()
                if matches.count == 1 || matches[0].size <= prefixBytes {
                    if matches.count > 1 { output.sets.append(DuplicateSet(files: matches.map(\.node))) }
                    completed += matches.count
                    report.update(completed: completed, total: total)
                    continue
                }
                var byDigest: [SHA256Digest: [FileNode]] = [:]
                for candidate in matches {
                    let observation = try DuplicateIO.read(candidate, limit: nil, buffer: &buffer, checkCancellation: checkCancellation)
                    completed += 1
                    report.update(completed: completed, total: total)
                    guard let observation else { output.unreadable.insert(candidate.node.id); continue }
                    output.observations[candidate.node.id] = observation
                    byDigest[observation.digest, default: []].append(candidate.node)
                }
                output.sets += byDigest.values.filter { $0.count > 1 }.map { DuplicateSet(files: $0) }
            }
        }
        try checkCancellation()
        report.update(completed: completed, total: total, force: true)
        output.sets.sort(by: ordered)
        return output
    }

    static func ordered(_ a: DuplicateSet, _ b: DuplicateSet) -> Bool {
        let bytesA = a.offeredBytes, bytesB = b.offeredBytes
        if bytesA != bytesB { return bytesA > bytesB }
        return a.files[0].path.utf8.lexicographicallyPrecedes(b.files[0].path.utf8)
    }
}

/// Holds the cancellation bit for a single blocking queue operation. The continuation
/// resumes after the worker exits, so a caller can wait before releasing access grants.
final class DuplicateCancellation: Sendable {
    private let cancelled = Mutex(false)
    func cancel() { cancelled.withLock { $0 = true } }
    func check() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
}

enum DuplicateIO {
    static let chunkSize = 1 << 20
    private static let queue = DispatchQueue(label: "DiskUnbloat.duplicates", qos: .userInitiated)

    struct Observation: Sendable {
        let digest: SHA256Digest
        let links: UInt16
    }

    static func run<Output: Sendable>(_ work: @escaping @Sendable (DuplicateCancellation) throws -> Output) async throws -> Output {
        let cancellation = DuplicateCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
                    guard previous >= 0, setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                                                       IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
                        continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                        return
                    }
                    let result = Result { try cancellation.check(); return try work(cancellation) }
                    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
                    continuation.resume(with: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    static func read(
        _ candidate: DuplicateCandidate, limit: Int?, buffer: inout [UInt8],
        cached: Observation? = nil, requireSingleLink: Bool = false, checkCancellation: () throws -> Void
    ) throws -> Observation? {
        func matches(_ info: stat) -> Bool {
            (info.st_mode & S_IFMT) == S_IFREG && !FileIdentity.isDataless(info)
                && info.st_size == candidate.size && FileIdentity.identity(info) == candidate.node.identity
                && FileIdentity.fingerprint(info) == candidate.node.fingerprint
        }

        try checkCancellation()
        let path = candidate.node.path
        var info = stat()
        guard lstat(path, &info) == 0, matches(info) else { return nil }
        if requireSingleLink, info.st_nlink != 1 { return nil }
        if let cached, cached.links == info.st_nlink { return cached }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, matches(info), !requireSingleLink || info.st_nlink == 1 else { return nil }
        _ = fcntl(descriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        var remaining = min(candidate.size, limit.map(Int64.init) ?? candidate.size)
        while remaining > 0 {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, Int(min(remaining, Int64($0.count))))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            remaining -= Int64(count)
        }
        try checkCancellation()
        guard fstat(descriptor, &info) == 0, matches(info), !requireSingleLink || info.st_nlink == 1 else { return nil }
        let links = info.st_nlink
        guard lstat(path, &info) == 0, matches(info) else { return nil }
        return Observation(digest: hasher.finalize(), links: links)
    }
}

struct DuplicateProgressReporter {
    let stage: DuplicateProgress.Stage
    private var previous = ContinuousClock.now
    let send: (DuplicateProgress) -> Void

    init(stage: DuplicateProgress.Stage, send: @escaping (DuplicateProgress) -> Void) {
        self.stage = stage
        self.send = send
    }

    mutating func update(completed: Int, total: Int?, force: Bool = false) {
        let now = ContinuousClock.now
        guard force || previous.duration(to: now) >= .milliseconds(200) else { return }
        previous = now
        send(DuplicateProgress(stage: stage, completed: completed, total: total))
    }
}
