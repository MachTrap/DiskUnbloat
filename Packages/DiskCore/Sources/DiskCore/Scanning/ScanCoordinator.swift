import Foundation
import Darwin

public protocol ScanServing: Sendable {
    func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent>
    func cancel() async
}
public actor ScanCoordinator: ScanServing {
    private var runningTask: Task<Void, Never>?
    public init() {}
    public func cancel() { runningTask?.cancel() }
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
                var protectedUnreadable = false
                for target in await worker.preflightTargets() {
                    if Task.isCancelled { break }
                    if await worker.probe(target) == .containsDeniedChildren { protectedUnreadable = true }
                }
                if protectedUnreadable { continuation.yield(.protectedFoldersRefused) }
                do {
                    while !Task.isCancelled {
                        let batch = await worker.next()
                        try await index.insert(batch.nodes)
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
                } catch { continuation.yield(.failed(error.localizedDescription)) }
                continuation.finish()
            }
            runningTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
