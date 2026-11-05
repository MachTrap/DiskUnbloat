import Foundation
import Observation
import Darwin
import DiskCore

struct PendingGroup: Sendable {
    var title: String
    var roots: [URL]
}

@MainActor @Observable final class ScanViewModel {
    @ObservationIgnored private let coordinator: any ScanServing
    @ObservationIgnored private let storage: ScanSessionStore
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var index: ScanIndex?
    var root: URL?
    var pendingRoot: URL?
    /// A grouped quick action waiting to become the active scan scope.
    var pendingGroup: PendingGroup?
    private(set) var groupTitle: String?
    private(set) var groupRoots: [URL] = []
    var options = ScanOptions() {
        didSet { defaults.set(options.longUnusedDays, forKey: Self.longUnusedDaysKey) }
    }
    private var sessionOptions = ScanOptions()
    /// The "long-unused" definition persists across launches; it is a definition, not
    /// per-scan state, and applies to automatic selection without a rescan.
    static let longUnusedDaysKey = "longUnusedDays"
    var isGroupScan: Bool { groupRoots.count > 1 }
    /// Every authorized scan scope: the single root, or all locations of a grouped scan.
    var roots: [URL] { groupRoots.isEmpty ? (root.map { [$0] } ?? []) : groupRoots }
    var exclusionText = ""
    /// Folders measured as one item (names, or absolute/`~` paths), one per line. Persists
    /// across launches: it is a scanning preference, not per-scan state.
    var summarizedText = "" {
        didSet { defaults.set(summarizedText, forKey: Self.summarizedFoldersKey) }
    }
    static let summarizedFoldersKey = "summarizedFolders"
    var showSetup = false
    var stage: ScanStage = .reading
    private(set) var committingRefresh = false
    private(set) var cancellationRequested = false
    private(set) var startedAt: Date?
    var showIssues = false
    /// The preflight observed macOS-protected folders refusing reads with no consent
    /// channel (other applications' app data on macOS 26+); the issues sheet explains
    /// the Full Disk Access decision instead of leaving raw permission errors.
    private(set) var protectedFoldersRefused = false
    /// Protected directory the consent preflight is currently opening; macOS holds the
    /// open until its consent dialog is answered. `nil` outside the preflight.
    private(set) var awaitingPermission: String? {
        didSet { if oldValue != awaitingPermission { noteConsentWait(ended: oldValue) } }
    }
    @ObservationIgnored var diagnostics: DiagnosticsLog?
    /// Set by the workspace from the Full Disk Access decision before each scan.
    @ObservationIgnored var consentPolicy: ConsentPolicy = .fullDiskAccess
    /// The catalog home(s) the consent policy applies to.
    @ObservationIgnored var homePaths: [String]?
    @ObservationIgnored private var consentWaitStarted: Date?
    private(set) var scanning = false
    private(set) var snapshot: ScanSnapshot?
    private(set) var issues: [String] = []
    /// The same issues grouped by reason, largest group first: hundreds of identical
    /// macOS refusals read as one line with a count instead of a wall of paths.
    private(set) var issueGroups: [IssueGroup] = []
    struct IssueGroup: Identifiable, Equatable {
        let message: String
        let paths: [String]
        /// Refusals by macOS privacy protection (Full Disk Access is the remedy), decided on
        /// the untranslated message so it holds in every language.
        let isProtection: Bool
        var id: String { message }

        static func isProtection(raw: String) -> Bool {
            raw.localizedCaseInsensitiveContains("not permitted") || raw.hasPrefix("Protected by macOS")
        }
    }

    private func setIssues(_ records: [ScanIssue]) {
        issues = records.map { $0.path + ": " + L10n.text($0.message) }
        var grouped: [String: [String]] = [:]; var order: [String] = []; var protection: [String: Bool] = [:]
        for record in records {
            let message = L10n.text(record.message)
            if grouped[message] == nil { order.append(message); protection[message] = IssueGroup.isProtection(raw: record.message) }
            grouped[message, default: []].append(record.path)
        }
        issueGroups = order.map { IssueGroup(message: $0, paths: grouped[$0] ?? [], isProtection: protection[$0] ?? false) }
            .sorted { $0.paths.count > $1.paths.count }
    }
    /// Used space on the scanned volume; the honest denominator for overall progress.
    private(set) var volumeUsedBytes: Int64?

    init(coordinator: any ScanServing, storage: ScanSessionStore = ScanSessionStore(), defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.storage = storage
        self.defaults = defaults
        storage.purgeAbandonedIndexes()
        options.longUnusedDays = defaults.object(forKey: Self.longUnusedDaysKey) as? Int ?? 90
        summarizedText = defaults.string(forKey: Self.summarizedFoldersKey) ?? ScanOptions.defaultSummarizedFolders.joined(separator: "\n")
    }

    /// Approximate share of the volume's used space already read. Subfolder scans may finish
    /// below high values; completion always shows 100.
    var progressPercent: Int? {
        if stage == .preparingMap { return 100 }
        guard scanning, let snapshot, let used = volumeUsedBytes, used > 0 else { return nil }
        return min(99, max(1, Int(Double(max(0, snapshot.bytes)) / Double(used) * 100)))
    }

    private static func volumeUsedBytes(for url: URL) -> Int64? {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return nil }
        let used = (Int64(stats.f_blocks) - Int64(stats.f_bfree)) * Int64(stats.f_bsize)
        return used > 0 ? used : nil
    }

    var status: String {
        if scanning { return L10n.text("Scanning…") }
        guard let snapshot else { return L10n.text("Ready to explore") }
        if snapshot.cancelled { return L10n.text("Cancelled · partial results") }
        return snapshot.complete ? L10n.text("Scan complete") : L10n.text("Partial scan · some locations unavailable")
    }

    /// Prepares state synchronously before the workspace starts its lifecycle task.
    /// The roots `prepare()` would scan, without starting a session.
    var plannedRoots: [URL] {
        if pendingRoot == nil, let group = pendingGroup, !group.roots.isEmpty { return group.roots }
        if let chosen = pendingRoot { return [chosen] }
        if !groupRoots.isEmpty { return groupRoots }
        return root.map { [$0] } ?? []
    }

    func prepare() -> ScanRequest? {
        guard !scanning else { return nil }
        // A grouped quick action, or the same scope again after a cleanup rescan.
        var group = pendingGroup
        if pendingRoot == nil, group == nil, !groupRoots.isEmpty { group = PendingGroup(title: groupTitle ?? "", roots: groupRoots) }
        if pendingRoot == nil, let group, !group.roots.isEmpty {
            pendingGroup = nil
            return startSession(roots: group.roots, title: group.title, volume: group.roots.first)
        }
        guard let chosen = pendingRoot ?? root else { return nil }
        if pendingRoot != nil { pendingGroup = nil }
        return startSession(roots: [chosen], title: nil, volume: chosen)
    }

    private func startSession(roots: [URL], title: String?, volume: URL?) -> ScanRequest {
        refreshNode = nil; previousSnapshot = nil
        root = roots[0]; pendingRoot = nil
        groupTitle = title; groupRoots = title == nil ? [] : roots
        showSetup = false; stage = .reading; cancellationRequested = false; startedAt = Date(); scanning = true; snapshot = nil; issues = []; issueGroups = []
        protectedFoldersRefused = false; awaitingPermission = nil
        volumeUsedBytes = volume.flatMap(Self.volumeUsedBytes(for:))
        options.consentPolicy = consentPolicy
        options.homePaths = homePaths
        options.exclusions = exclusionText.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        options.summarizedFolders = summarizedText.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.hasPrefix("~") ? NSString(string: $0).expandingTildeInPath : $0 }
        return ScanRequest(root: roots[0], extraRoots: title == nil ? [] : Array(roots.dropFirst()), groupTitle: title ?? "", options: options)
    }

    /// Consent waits longer than half a second are what a stuck-looking scan is made of.
    private func noteConsentWait(ended path: String?) {
        if let path, let started = consentWaitStarted {
            let seconds = Date().timeIntervalSince(started)
            if seconds >= 0.5 { diagnostics?.record("consent", String(format: "Waited %.1f s on %@", seconds, URL(fileURLWithPath: path).lastPathComponent)) }
        }
        consentWaitStarted = awaitingPermission == nil ? nil : Date()
    }

    private func logOutcome(_ prefix: String) {
        let started = startedAt.map { String(format: " after %.1f s", Date().timeIntervalSince($0)) } ?? ""
        let s = snapshot
        diagnostics?.record("scan", "\(prefix)\(started): \(s?.items ?? 0) items, \(s?.folders ?? 0) folders, \(s?.bytes ?? 0) bytes, \(s?.errors ?? 0) issues\(s?.cancelled == true ? ", cancelled" : "")\(protectedFoldersRefused ? ", protected folders refused" : "")")
    }

    func run(_ request: ScanRequest) async throws {
        defer { scanning = false; awaitingPermission = nil }
        diagnostics?.record("scan", "Started \(request.roots.map(\.path).joined(separator: ", "))")
        await discardIndex()
        sessionOptions = request.options
        let db = try storage.makeIndex()
        index = db
        let stream = await coordinator.scan(request, into: db)
        if cancellationRequested { await coordinator.cancel() }
        var lastIssuesRefresh = Date.distantPast
        for await event in stream {
            switch event {
            case .stage(let stage):
                self.stage = stage
                diagnostics?.record("scan", "Stage: \(stage.rawValue)" + (startedAt.map { String(format: " at %.1f s", Date().timeIntervalSince($0)) } ?? ""))
            case .protectedFoldersRefused: protectedFoldersRefused = true
            case .awaitingPermission(let path): awaitingPermission = path
            case .slowRead(let path, let seconds): diagnostics?.record("scan", String(format: "Read blocked %.1f s: %@", seconds, path))
            case .progress(let progress):
                snapshot = progress; awaitingPermission = nil
                // Unreachable locations are listable while the scan is still running.
                if progress.errors > 0, Date().timeIntervalSince(lastIssuesRefresh) >= 1 {
                    lastIssuesRefresh = Date()
                    setIssues(await db.issues())
                }
            case .finished(let result): snapshot = result; logOutcome("Finished")
            case .failed(let error):
                diagnostics?.record("scan", "Failed: \(error)")
                throw ScanFailure(message: error)
            }
        }
        if cancellationRequested, let result = snapshot {
            snapshot = ScanSnapshot(items: result.items,bytes: result.bytes,elapsed: result.elapsed,errors: result.errors,cancelled: true,complete: false,folders: result.folders,currentFolder: result.currentFolder)
        }
        setIssues(await db.issues())
    }

    private(set) var refreshNode: FileNode?
    @ObservationIgnored private var previousSnapshot: ScanSnapshot?

    /// Refresh targets must sit inside one of the authorized scopes; grouped scans list
    /// every location, so a secondary cache folder can refresh too.
    func prepareRefresh(_ node: FileNode) -> ScanRequest? {
        guard !scanning, let root, node.isDirectory, !node.isSymbolicLink, !node.isGroupRoot else { return nil }
        let scopes = groupRoots.isEmpty ? [root] : groupRoots
        guard let scope = scopes.first(where: {
            let path = canonicalURL($0).path
            return node.path.isWithin(path)
        }) else { return nil }
        let canonical = canonicalURL(scope).path
        refreshNode = node; previousSnapshot = snapshot
        scanning = true; stage = .reading; cancellationRequested = false; startedAt = Date(); snapshot = nil
        volumeUsedBytes = Self.volumeUsedBytes(for: root)
        let relative = String(node.path.dropFirst(canonical.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ScanRequest(root: relative.isEmpty ? scope : scope.appendingPathComponent(relative), options: sessionOptions)
    }

    func runRefresh(_ request: ScanRequest, node: FileNode) async throws -> Bool {
        defer { scanning = false; committingRefresh = false; awaitingPermission = nil }
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
                case .protectedFoldersRefused: protectedFoldersRefused = true
                case .awaitingPermission(let path): awaitingPermission = path
                case .slowRead(let path, let seconds): diagnostics?.record("scan", String(format: "Read blocked %.1f s: %@", seconds, path))
                }
            }
            if cancellationRequested || snapshot?.cancelled == true { await storage.discard(staging); return false }
            guard await staging.node(1) != nil else { throw ScanFailure(message: L10n.text("The folder could not be read.")) }
            committingRefresh = true; stage = .preparingMap
            await staging.close()
            _ = try await index.replaceBranch(BranchRefreshRequest(nodeID: node.id, identity: node.identity), stagingURL: staging.url)
            await storage.discard(staging)
            setIssues(await index.issues())
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
    /// Stops waiting on macOS consent dialogs and starts reading now; folders whose
    /// dialog is still open are read (or refused) when the user answers it.
    func skipPermissionRequests() async {
        diagnostics?.record("consent", "User skipped the remaining permission checks")
        await coordinator.skipPermissionPreflight()
    }

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
