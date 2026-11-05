import AgentDevKitHost
import Foundation
import Synchronization
import DiskCore

/// Services for the agent Testing app. Everything that could touch real user data or
/// real consent state is replaced or isolated:
/// - the home folder is a generated fixture tree inside the profile (unless
///   `--diskunbloat-real-home` is passed for deliberate TCC experiments);
/// - scan indexes live in the profile;
/// - cleanup is a dry run that records plans and never moves or deletes anything;
/// - Full Disk Access is reported granted for the fixture home, real otherwise.
@MainActor final class TestingComposition {
    static let realHomeFlag = "--diskunbloat-real-home"
    let options: LaunchOptions
    let profileDirectory: URL
    let profileReady: Bool
    let home: URL
    let usesRealHome: Bool
    let scanner = TestingScanner()
    let cleanup = DryRunCleanupService()
    let fullDiskAccess: TestingFullDiskAccess

    init(options: LaunchOptions, realHome: Bool) {
        self.options = options
        var directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloatTesting-\(UUID().uuidString)", isDirectory: true)
        var ready = false
        if let profile = try? TestingProfile(appName: "DiskUnbloatTesting", profile: options.profile) {
            directory = profile.directory; ready = true
        }
        profileDirectory = directory
        profileReady = ready
        usesRealHome = realHome
        let generated = directory.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        // Scanned paths are canonical (`/private/var/…`); curated rules match against the
        // catalog home, so it must be canonical too or no rule would ever apply.
        home = realHome ? LocationCatalog().home : Self.canonical(generated)
        fullDiskAccess = TestingFullDiskAccess(real: realHome)
    }

    private static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func makeWorkspace() -> WorkspaceViewModel {
        WorkspaceViewModel(
            coordinator: scanner, cleanupService: cleanup,
            settings: SettingsViewModel(history: ScanHistoryStore(base: profileDirectory.appendingPathComponent("History", isDirectory: true))),
            fullDiskAccess: fullDiskAccess,
            catalog: LocationCatalog(home: home),
            storage: ScanSessionStore(base: profileDirectory.appendingPathComponent("Scans", isDirectory: true)),
            toolRunner: DryRunToolRunner())
    }
}

/// Forwards to a real `ScanCoordinator`. The `permission-wait` fixture swaps in one
/// whose consent probe blocks until released, simulating an unanswered macOS dialog.
actor TestingScanner: ScanServing {
    private var inner = ScanCoordinator()
    private let gate = Mutex<DispatchSemaphore?>(nil)

    func useRealPreflight() { release(); inner = ScanCoordinator() }

    func useBlockingPreflight(target: URL) {
        let semaphore = DispatchSemaphore(value: 0)
        gate.withLock { $0 = semaphore }
        inner = ScanCoordinator(
            preflightTargets: { _ in [ScanPermissionPreflight.Target(url: target, depth: .directoryOnly)] },
            preflightProbe: { _, _ in semaphore.wait(); semaphore.signal(); return .readable })
    }

    /// Answers the simulated dialog.
    func release() { gate.withLock { $0?.signal(); $0 = nil } }

    func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent> { await inner.scan(request, into: index) }
    func cancel() async { await inner.cancel() }
    func skipPermissionPreflight() async { await inner.skipPermissionPreflight() }
}

/// Records every plan and reports success without touching the filesystem.
actor DryRunCleanupService: CleanupServing {
    private(set) var plans: [CleanupPlan] = []
    func execute(_ plan: CleanupPlan) -> [CleanupResult] {
        plans.append(plan)
        return plan.items.map { CleanupResult(id: $0.node.id, path: $0.node.path, succeeded: true, message: "Dry run — nothing was moved") }
    }
    func planCount() -> Int { plans.count }
}

/// Developer-tool commands are never executed in the Testing app.
struct DryRunToolRunner: ToolCommandRunning {
    func run(executable: String, arguments: [String], timeout: Duration) async -> ToolRunResult {
        ToolRunResult(status: 0, output: "Dry run — would run: \(([executable] + arguments).joined(separator: " "))")
    }
}

struct TestingFullDiskAccess: FullDiskAccessChecking {
    let real: Bool
    func isGranted() async -> Bool { real ? await SystemFullDiskAccessProbe().isGranted() : true }
}
