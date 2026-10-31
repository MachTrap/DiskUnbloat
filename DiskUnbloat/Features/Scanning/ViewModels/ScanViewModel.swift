import Foundation
import Observation
import DiskCore

@MainActor @Observable final class ScanViewModel {
    @ObservationIgnored private let coordinator: any ScanServing
    @ObservationIgnored private let storage: ScanSessionStore
    private(set) var index: ScanIndex?
    var root: URL?
    var pendingRoot: URL?
    var options = ScanOptions()
    private var sessionOptions = ScanOptions()
    var exclusionText = ""
    var showSetup = false
    var stage: ScanStage = .reading
    private(set) var committingRefresh = false
    private(set) var cancellationRequested = false
    private(set) var startedAt: Date?
    var showIssues = false
    private(set) var scanning = false
    private(set) var snapshot: ScanSnapshot?
    private(set) var issues: [String] = []

    init(coordinator: any ScanServing, storage: ScanSessionStore = ScanSessionStore()) {
        self.coordinator = coordinator
        self.storage = storage
        storage.purgeAbandonedIndexes()
    }

    var status: String {
        if scanning { return L10n.text("Scanning…") }
        guard let snapshot else { return L10n.text("Ready to explore") }
        if snapshot.cancelled { return L10n.text("Cancelled · partial results") }
        return snapshot.complete ? L10n.text("Scan complete") : L10n.text("Partial scan · some locations unavailable")
    }

    /// Prepares state synchronously before the workspace starts its lifecycle task.
    func prepare() -> ScanRequest? {
        guard let chosen = pendingRoot ?? root, !scanning else { return nil }
        refreshNode = nil; previousSnapshot = nil
        root = chosen; pendingRoot = nil
        showSetup = false; stage = .reading; cancellationRequested = false; startedAt = Date(); scanning = true; snapshot = nil; issues = []
        options.exclusions = exclusionText.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ScanRequest(root: chosen, options: options)
    }

    func run(_ request: ScanRequest) async throws {
        defer { scanning = false }
        await discardIndex()
        sessionOptions = request.options
        let db = try storage.makeIndex()
        index = db
        let stream = await coordinator.scan(request, into: db)
        if cancellationRequested { await coordinator.cancel() }
        for await event in stream {
            switch event {
            case .stage(let stage): self.stage = stage
            case .progress(let progress): snapshot = progress
            case .finished(let result): snapshot = result
            case .failed(let error): throw ScanFailure(message: error)
            }
        }
        if cancellationRequested, let result = snapshot {
            snapshot = ScanSnapshot(items: result.items,bytes: result.bytes,elapsed: result.elapsed,errors: result.errors,cancelled: true,complete: false,folders: result.folders,currentFolder: result.currentFolder)
        }
        issues = await db.issues().map { $0.path + ": " + L10n.text($0.message) }
    }

    private(set) var refreshNode: FileNode?
    @ObservationIgnored private var previousSnapshot: ScanSnapshot?

    func prepareRefresh(_ node: FileNode) -> ScanRequest? {
        guard !scanning, let root, node.isDirectory, !node.isSymbolicLink else { return nil }
        let rootPath = canonicalURL(root).path
        guard rootPath == "/" || node.path == rootPath || node.path.hasPrefix(rootPath + "/") else { return nil }
        refreshNode = node; previousSnapshot = snapshot
        scanning = true; stage = .reading; cancellationRequested = false; startedAt = Date(); snapshot = nil
        let relative = String(node.path.dropFirst(canonicalURL(root).path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ScanRequest(root: relative.isEmpty ? root : root.appendingPathComponent(relative), options: sessionOptions)
    }

    func runRefresh(_ request: ScanRequest, node: FileNode) async throws -> Bool {
        defer { scanning = false; committingRefresh = false }
        guard let index else { return false }
        try await index.validateBranch(BranchRefreshRequest(nodeID: node.id, identity: node.identity))
        let staging = try storage.makeIndex()
        do {
            let stream = await coordinator.scan(request, into: staging)
            if cancellationRequested { await coordinator.cancel() }
            for await event in stream {
                switch event {
                case .stage(let value): stage = value
                case .progress(let value), .finished(let value): snapshot = value
                case .failed(let error): throw ScanFailure(message: error)
                }
            }
            if cancellationRequested || snapshot?.cancelled == true { await storage.discard(staging); return false }
            guard await staging.node(1) != nil else { throw ScanFailure(message: L10n.text("The folder could not be read.")) }
            committingRefresh = true; stage = .preparingMap
            await staging.close()
            _ = try await index.replaceBranch(BranchRefreshRequest(nodeID: node.id, identity: node.identity), stagingURL: staging.url)
            await storage.discard(staging)
            issues = await index.issues().map { $0.path + ": " + L10n.text($0.message) }
            if let result = snapshot {
                let remainsCancelled = previousSnapshot?.cancelled == true && node.parentID != nil
                snapshot = ScanSnapshot(items: result.items, bytes: result.bytes, elapsed: result.elapsed, errors: issues.count, cancelled: remainsCancelled, complete: issues.isEmpty && !remainsCancelled, folders: result.folders, currentFolder: result.currentFolder)
            }
            return true
        } catch { await storage.discard(staging); throw error }
    }

    func finishRefresh(restorePrevious: Bool) {
        if restorePrevious { snapshot = previousSnapshot }
        previousSnapshot = nil; refreshNode = nil
    }

    func requestCancellation() { if !committingRefresh { cancellationRequested = true } }
    func cancel() async { guard !committingRefresh else { return }; cancellationRequested = true; await coordinator.cancel() }

    func discardIndex() async {
        guard let index else { return }
        self.index = nil
        await storage.discard(index)
    }

    private struct ScanFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
