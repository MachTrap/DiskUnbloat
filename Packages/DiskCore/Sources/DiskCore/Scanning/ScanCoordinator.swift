import Foundation
import Darwin
import Synchronization

public protocol ScanServing: Sendable {
    func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent>
    func cancel() async
    /// Stops the consent preflight of the running scan and starts enumerating now.
    func skipPermissionPreflight() async
}
public actor ScanCoordinator: ScanServing {
    public typealias PreflightTargets = @Sendable (ScanRequest) -> [ScanPermissionPreflight.Target]
    public typealias PreflightProbe = @Sendable (ScanPermissionPreflight.Target, [String]) -> ScanPermissionPreflight.ProbeOutcome
    private var runningTask: Task<Void, Never>?
    private let preflightTargets: PreflightTargets
    private let preflightProbe: PreflightProbe
    private var skipRequested = false
    private var pendingProbe: PreflightWaiter?
    /// The preflight seams exist so tests can simulate a consent dialog that never gets
    /// answered; production always uses the real TCC probes.
    public init(preflightTargets: @escaping PreflightTargets = { ScanPermissionPreflight.targets(for: $0) },
                preflightProbe: @escaping PreflightProbe = { ScanPermissionPreflight.probe($0, excludedPaths: $1) }) {
        self.preflightTargets = preflightTargets; self.preflightProbe = preflightProbe
    }
    public func cancel() { runningTask?.cancel(); pendingProbe?.abandon() }
    public func skipPermissionPreflight() { skipRequested = true; pendingProbe?.abandon() }
    public func scan(_ request: ScanRequest, into index: ScanIndex) -> AsyncStream<ScanEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task {
                let worker = ParallelEnumeration(request)
                // Workers block on their backlog until drained; every exit path stops them.
                defer { worker.cancel() }
                let start = Date(); var lastUpdate = Date.distantPast
                var count = 0; var bytes: Int64 = 0; var errors = 0; var folders = 0; var currentFolder = request.root.path
                continuation.yield(.stage(.reading))
                // Upfront consent probing: every prompt macOS can offer fires before deep
                // enumeration, and refusals (protected other-app data, media libraries)
                // surface once as guidance instead of dozens of per-path mystery errors.
                // Each open can block until the user answers a consent dialog (or on a
                // stuck File Provider), so it runs on its own thread and is abandoned —
                // never awaited forever — on cancel or skip.
                var protectedUnreadable = false
                skipRequested = false
                let excluded = request.options.exclusions.map { canonicalURL(URL(fileURLWithPath: $0)).path }
                let targets = await PreflightWaiter.run { [preflightTargets] in preflightTargets(request) } ?? []
                for target in targets {
                    if Task.isCancelled || skipRequested { break }
                    // Registered before the event goes out, and the skip flag rechecked after,
                    // so a skip sent in reaction to the event always reaches this waiter.
                    let waiter = PreflightWaiter()
                    pendingProbe = waiter
                    continuation.yield(.awaitingPermission(target.url.path))
                    if skipRequested || Task.isCancelled { waiter.abandon() }
                    let outcome = await waiter.wait { [preflightProbe] in preflightProbe(target, excluded) }
                    pendingProbe = nil
                    if outcome == .containsDeniedChildren { protectedUnreadable = true }
                }
                continuation.yield(.awaitingPermission(nil))
                if protectedUnreadable { continuation.yield(.protectedFoldersRefused) }
                if Task.isCancelled {
                    continuation.yield(.finished(ScanSnapshot(items: 0, bytes: 0, elapsed: Date().timeIntervalSince(start), errors: 0, cancelled: true, complete: false)))
                    continuation.finish(); return
                }
                do {
                    try await index.beginBulkLoad()
                    while !Task.isCancelled {
                        let batch = await worker.next()
                        try await index.insert(batch.nodes, derived: batch.derived)
                        count += batch.nodes.count
                        folders += batch.nodes.filter(\.isDirectory).count
                        if let folder = batch.currentFolder { currentFolder = folder }
                        bytes += batch.bytes
                        errors += batch.issues.count
                        for issue in batch.issues { await index.issue(path: issue.0, message: issue.1) }
                        if Date().timeIntervalSince(lastUpdate) >= 0.2 {
                            continuation.yield(.progress(ScanSnapshot(items: count, bytes: bytes, elapsed: Date().timeIntervalSince(start), errors: errors, cancelled: false, complete: false, folders: folders, currentFolder: currentFolder)))
                            lastUpdate = Date()
                        }
                        if batch.done { break }
                    }
                    continuation.yield(.stage(.aggregating))
                    try await index.aggregate()
                    continuation.yield(.finished(ScanSnapshot(items: count, bytes: bytes, elapsed: Date().timeIntervalSince(start), errors: errors, cancelled: Task.isCancelled, complete: !Task.isCancelled && errors == 0, folders: folders, currentFolder: currentFolder)))
                } catch {
                    try? await index.endBulkLoad()
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            runningTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Runs one blocking preflight call on a dedicated thread (with dataless-file
/// materialization off, like the enumeration workers) and resumes its awaiter exactly
/// once: with the result, or with `nil` when abandoned. An abandoned call keeps its
/// thread until macOS returns, but the scan no longer waits for it.
final class PreflightWaiter: Sendable {
    private struct State { var continuation: CheckedContinuation<ScanPermissionPreflight.ProbeOutcome?, Never>?; var done = false }
    private let state = Mutex(State())

    func wait(_ body: @escaping @Sendable () -> ScanPermissionPreflight.ProbeOutcome) async -> ScanPermissionPreflight.ProbeOutcome? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyDone = state.withLock { state -> Bool in
                    if state.done { return true }
                    state.continuation = continuation; return false
                }
                if alreadyDone { continuation.resume(returning: nil); return }
                Self.spawn { self.finish(body()) }
            }
        } onCancel: { abandon() }
    }

    func abandon() { finish(nil) }

    private func finish(_ outcome: ScanPermissionPreflight.ProbeOutcome?) {
        let continuation = state.withLock { state -> CheckedContinuation<ScanPermissionPreflight.ProbeOutcome?, Never>? in
            guard !state.done else { return nil }
            state.done = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: outcome)
    }

    /// Target discovery only stats paths, but on the same no-materialization thread.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in spawn { continuation.resume(returning: body()) } }
    }

    private static func spawn(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            body()
        }
        thread.qualityOfService = .userInitiated
        thread.name = "DiskUnbloat.preflight"
        thread.start()
    }
}
