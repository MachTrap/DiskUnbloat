import Foundation
import DiskCore

enum DuplicateReviewFilter: String, CaseIterable, Identifiable {
    case all, files, folders, selected
    var id: Self { self }

    var title: String {
        switch self {
        case .all: L10n.text("All matches")
        case .files: L10n.text("Files")
        case .folders: L10n.text("Matching folders")
        case .selected: L10n.text("Selected")
        }
    }
}

struct DuplicateReviewGroup: Identifiable, Sendable {
    enum Match: Sendable {
        case file(DuplicateSet)
        case folder(DuplicateFolderSet)
    }

    enum SupportCoverage: Equatable, Sendable {
        case none, mixed, all
    }

    let match: Match
    let copies: [FileNode]
    let commonParent: String
    let support: [Int64: SupportCoverage]

    var id: Int64 {
        switch match {
        case .file(let set): set.id
        case .folder(let set): set.id
        }
    }

    var title: String { copies.first?.name ?? "" }

    var isFolder: Bool {
        if case .folder = match { true } else { false }
    }

    var fileCount: Int {
        if case .folder(let set) = match { set.fileCount } else { 1 }
    }

    var relatedFolderIDs: [Int64] {
        if case .file(let set) = match { set.relatedFolderIDs } else { [] }
    }

    init(_ match: Match, safety: SafetyClassification) {
        self.match = match
        switch match {
        case .file(let set):
            copies = set.files
            support = Dictionary(uniqueKeysWithValues: set.files.map { file in
                (file.id, safety.level(of: file.path) == nil ? .none : .all)
            })
        case .folder(let set):
            copies = set.folders
            support = Dictionary(uniqueKeysWithValues: set.folders.map { folder in
                let files = set.files(in: folder)
                let tagged = files.count { safety.level(of: $0.path) != nil }
                let coverage: SupportCoverage = tagged == 0 ? .none : tagged == files.count ? .all : .mixed
                return (folder.id, coverage)
            })
        }
        commonParent = Self.sharedParent(copies.map(\.path))
    }

    func keeper(_ strategy: DuplicateKeepStrategy) -> FileNode {
        switch match {
        case .file(let set): set.keeper(strategy)
        case .folder(let set): set.keeper(strategy)
        }
    }

    func files(in copy: FileNode) -> [FileNode] {
        if case .folder(let set) = match { set.files(in: copy) } else { [copy] }
    }

    func entries(copy: FileNode, keeper: FileNode) -> [CleanupEntry] {
        zip(files(in: copy), files(in: keeper)).map { copy, kept in
            CleanupEntry(node: copy, operation: .remove, survivor: .init(kept))
        }
    }

    func allocatedBytes(in copy: FileNode) -> Int64 {
        files(in: copy).reduce(0) { $0 + $1.knownSize(for: .allocated) }
    }

    func differingPath(of node: FileNode) -> String {
        guard !commonParent.isEmpty else { return node.path }
        return String(node.path.dropFirst(commonParent.count))
    }

    @concurrent static func sortedGroups(
        for search: DuplicateSearch, safety: SafetyClassification, strategy: DuplicateKeepStrategy
    ) async throws -> [Self] {
        var groups: [(group: Self, offeredBytes: Int64)] = []
        for set in search.sets {
            try Task.checkCancellation()
            let group = Self(.file(set), safety: safety)
            groups.append((group, group.offeredBytes(strategy: strategy)))
        }
        for set in search.folderSets {
            try Task.checkCancellation()
            let group = Self(.folder(set), safety: safety)
            groups.append((group, group.offeredBytes(strategy: strategy)))
        }
        return groups.sorted {
            if $0.offeredBytes != $1.offeredBytes { return $0.offeredBytes > $1.offeredBytes }
            return ($0.group.copies.first?.path ?? "", $0.group.id) < ($1.group.copies.first?.path ?? "", $1.group.id)
        }.map(\.group)
    }

    private func offeredBytes(strategy: DuplicateKeepStrategy) -> Int64 {
        let keeperID = keeper(strategy).id
        return copies.reduce(0) { $0 + ($1.id == keeperID ? 0 : allocatedBytes(in: $1)) }
    }

    private static func sharedParent(_ paths: [String]) -> String {
        let parents = paths.map { $0.split(separator: "/").dropLast() }
        guard var shared = parents.first else { return "" }
        for parent in parents.dropFirst() {
            let length = zip(shared, parent).prefix { $0.0.utf8.elementsEqual($0.1.utf8) }.count
            shared = shared.prefix(length)
            if shared.isEmpty { return "" }
        }
        return shared.isEmpty ? "" : "/" + shared.joined(separator: "/") + "/"
    }
}
