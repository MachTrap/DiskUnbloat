import CryptoKit
import Foundation

enum DuplicateFolderCoverageError: Error { case entryLimit }

/// Folders with matching indexed structure and identical file data at each relative path.
public struct DuplicateFolderSet: Sendable, Equatable, Identifiable {
    public let folders: [FileNode]
    private let filesByFolder: [Int64: [FileNode]]
    public var id: Int64 { folders[0].id }
    public var fileCount: Int { files(in: id).count }

    init(_ members: [(folder: FileNode, files: [FileNode])]) {
        folders = members.map(\.folder).sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        filesByFolder = Dictionary(uniqueKeysWithValues: members.map { ($0.folder.id, $0.files) })
    }

    public func keeper(_ strategy: DuplicateKeepStrategy) -> FileNode { strategy.keeper(in: folders) }

    /// Files are in the same relative-path order for every member of this folder set.
    public func files(in folderID: Int64) -> [FileNode] { filesByFolder[folderID, default: []] }
    public func files(in folder: FileNode) -> [FileNode] { files(in: folder.id) }
}

struct DuplicateFolderTree: Sendable {
    struct Entry: Sendable {
        let relativePath: String
        let node: FileNode
        let size: Int64?
    }
    let root: FileNode
    let entries: [Entry]

    func shape() throws -> SHA256Digest {
        var hash = SHA256()
        for entry in entries {
            try Task.checkCancellation()
            let name = Data(entry.relativePath.utf8)
            var length = UInt64(name.count).bigEndian
            var size = (entry.size ?? -1).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: name)
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
        }
        return hash.finalize()
    }
}

enum DuplicateFolderMatcher {
    struct Output {
        let files: [DuplicateSet]
        let sets: [DuplicateFolderSet]
        let unreadable: Set<Int64>
        let limitExceeded: Bool
    }

    private struct Member: Sendable {
        let root: FileNode
        let entryCount: Int
        let files: [FileNode]
    }

    private struct Verification: Sendable {
        var member: Member?
        var content: SHA256Digest?
        var observations: [Int64: DuplicateIO.Observation] = [:]
        var unreadable: Int64?
    }

    private struct FolderMembership: Equatable {
        let folderSet: Int64
        let relativePosition: Int
    }

    static func match(
        _ sets: [DuplicateSet], index: ScanIndex, revision: UInt64, entryLimit: Int,
        eligible: @escaping @Sendable (FileNode) -> Bool,
        observations: [Int64: DuplicateIO.Observation],
        progress: @escaping @Sendable (DuplicateProgress) -> Void
    ) async throws -> Output {
        let paths = try candidatePaths(in: sets)
        guard !paths.isEmpty else { return Output(files: sets, sets: [], unreadable: [], limitExceeded: false) }
        progress(.init(stage: .verifyingFolders, completed: 0, total: nil))
        var shapes: [SHA256Digest: [String]] = [:]
        var limitExceeded = false
        for path in paths {
            do {
                guard let tree = try await index.duplicateFolderTree(at: path, revision: revision, limit: entryLimit, eligible: eligible) else { continue }
                shapes[try tree.shape(), default: []].append(path)
            } catch DuplicateFolderCoverageError.entryLimit {
                limitExceeded = true
            }
        }

        let candidates = shapes.values.filter { $0.count > 1 }
            .sorted { $0[0].utf8.lexicographicallyPrecedes($1[0].utf8) }
        let total = candidates.reduce(0) { $0 + $1.count }
        var checked = 0
        var report = DuplicateProgressReporter(stage: .verifyingFolders, send: progress)
        var knownObservations = observations
        var matchingMembers: [[Member]] = []
        var unreadable: Set<Int64> = []
        for cohort in candidates {
            var byContent: [SHA256Digest: [Member]] = [:]
            for path in cohort {
                guard let tree = try await index.duplicateFolderTree(at: path, revision: revision, limit: entryLimit, eligible: eligible) else { continue }
                let result = try await verify(tree, observations: knownObservations)
                knownObservations.merge(result.observations) { _, fresh in fresh }
                if let failed = result.unreadable { unreadable.insert(failed) }
                if let member = result.member, let content = result.content {
                    byContent[content, default: []].append(member)
                }
                checked += 1
                report.update(completed: checked, total: total)
            }
            matchingMembers += byContent.values.filter { $0.count > 1 }
        }
        report.update(completed: checked, total: total, force: true)

        let folders = try outermostSets(matchingMembers)
        var membership: [Int64: FolderMembership] = [:]
        for folderSet in folders {
            for folder in folderSet.folders {
                for (offset, file) in folderSet.files(in: folder).enumerated() {
                    membership[file.id] = FolderMembership(folderSet: folderSet.id, relativePosition: offset)
                }
            }
        }
        let remaining = sets.compactMap { set -> DuplicateSet? in
            if let first = membership[set.files[0].id], set.files.allSatisfy({ membership[$0.id] == first }) {
                return nil
            }
            let related = Set(set.files.compactMap { membership[$0.id]?.folderSet }).sorted()
            return DuplicateSet(files: set.files, relatedFolderIDs: related)
        }
        return Output(files: remaining, sets: folders, unreadable: unreadable, limitExceeded: limitExceeded)
    }

    /// Identical files seed folder comparisons only at identical relative paths.
    /// Look up paths by suffix, so a file set with many copies requires no pairwise walk.
    private static func candidatePaths(in sets: [DuplicateSet]) throws -> [String] {
        var paths: Set<String> = []
        for set in sets {
            var firstBySuffix: [Data: String] = [:]
            for file in set.files {
                try Task.checkCancellation()
                var path = file.path as NSString
                var suffix = path.lastPathComponent
                while path.length > 1 {
                    path = path.deletingLastPathComponent as NSString
                    guard path.length > 1 else { break }
                    let folder = path as String
                    let key = Data(suffix.utf8)
                    if let first = firstBySuffix[key] {
                        if first != folder { paths.insert(first); paths.insert(folder) }
                    } else {
                        firstBySuffix[key] = folder
                    }
                    suffix = path.lastPathComponent + "/" + suffix
                }
            }
        }
        return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func verify(
        _ tree: DuplicateFolderTree, observations: [Int64: DuplicateIO.Observation]
    ) async throws -> Verification {
        let cached = Dictionary(uniqueKeysWithValues: tree.entries.compactMap { entry in
            observations[entry.node.id].map { (entry.node.id, $0) }
        })
        return try await DuplicateIO.run { cancellation in
            var result = Verification()
            var buffer = [UInt8](repeating: 0, count: DuplicateIO.chunkSize)
            var hash = SHA256()
            var files: [FileNode] = []
            for entry in tree.entries {
                try cancellation.check()
                guard let size = entry.size else { continue }
                let candidate = DuplicateCandidate(node: entry.node, size: size)
                guard let observation = try DuplicateIO.read(
                    candidate, limit: nil, buffer: &buffer, cached: cached[entry.node.id],
                    requireSingleLink: true, checkCancellation: cancellation.check
                ) else {
                    result.unreadable = entry.node.id
                    return result
                }
                if cached[entry.node.id] == nil { result.observations[entry.node.id] = observation }
                observation.digest.withUnsafeBytes { hash.update(bufferPointer: $0) }
                files.append(entry.node)
            }
            result.member = Member(root: tree.root, entryCount: tree.entries.count, files: files)
            result.content = hash.finalize()
            return result
        }
    }

    private static func outermostSets(_ groups: [[Member]]) throws -> [DuplicateFolderSet] {
        let sorted = groups.sorted {
            if $0[0].entryCount != $1[0].entryCount { return $0[0].entryCount > $1[0].entryCount }
            return $0[0].root.path.utf8.lexicographicallyPrecedes($1[0].root.path.utf8)
        }
        var occupied: Set<String> = []
        var occupiedParents: Set<String> = []
        var result: [DuplicateFolderSet] = []
        for group in sorted {
            try Task.checkCancellation()
            let available = group.filter { member in
                let path = member.root.path
                return !occupied.contains(path) && !occupiedParents.contains(path)
                    && !parents(of: path).contains(where: occupied.contains)
            }
            guard available.count > 1 else { continue }
            for member in available {
                occupied.insert(member.root.path)
                occupiedParents.formUnion(parents(of: member.root.path))
            }
            result.append(DuplicateFolderSet(available.map { ($0.root, $0.files) }))
        }
        return result
    }

    private static func parents(of path: String) -> [String] {
        var path = (path as NSString).deletingLastPathComponent
        var parents: [String] = []
        while path != "/" && !path.isEmpty {
            parents.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        return parents
    }
}
