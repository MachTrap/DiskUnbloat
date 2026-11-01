import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Test doubles shared across the presentation test suites.

/// Cleanup service whose every item reports success, to exercise post-cleanup navigation.
struct SucceedingCleanupService: CleanupServing {
    func execute(_ plan: CleanupPlan) async -> [CleanupResult] {
        plan.items.map { CleanupResult(id: $0.node.id, path: $0.node.path, succeeded: true, message: "Moved to Trash") }
    }
}

actor RecordingCleanupService: CleanupServing {
    private(set) var plans: [CleanupPlan] = []
    func execute(_ plan: CleanupPlan) async -> [CleanupResult] {
        plans.append(plan)
        return [] // Records intent only; never touches real filesystem paths.
    }
}

@MainActor final class StubBookmarkAccess: BookmarkAccessing {
    let url: URL
    var creationError: (any Error)?
    var canStart = true
    var isStale = false
    var started: [URL] = []
    var stopped: [URL] = []
    init(url: URL) { self.url = url }
    func makeBookmark(for url: URL) async throws -> Data {
        if let creationError { throw creationError }
        return Data([1])
    }
    func resolve(_ data: Data) async throws -> ResolvedBookmark { ResolvedBookmark(url: url, isStale: isStale) }
    func startAccessing(_ url: URL) -> Bool {
        guard canStart else { return false }
        started.append(url)
        return true
    }
    func stopAccessing(_ url: URL) { stopped.append(url) }
}

actor ControlledScanner: ScanServing {
    private var continuation: AsyncStream<ScanEvent>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent> {
        try? await index.insert([
            FileNode(id: 1,parentID: nil,path: "/fixture",name: "fixture",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "1"),
            FileNode(id: 2,parentID: 1,path: "/fixture/folder",name: "folder",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "2"),
            FileNode(id: 3,parentID: 2,path: "/fixture/folder/movie.mov",name: "movie.mov",isDirectory: false,logicalSize: 100,allocatedSize: 4096,modified: nil,identity: "3")
        ])
        try? await index.aggregate()
        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.stage(.reading))
            continuation.yield(.progress(ScanSnapshot(items: 3,bytes: 4096,elapsed: 1,errors: 0,cancelled: false,complete: false,folders: 2,currentFolder: "/fixture/folder")))
            waiters.forEach { $0.resume() }; waiters = []
        }
    }
    func ready() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(error: String? = nil, partial: Bool = false) {
        if let error { continuation?.yield(.failed(error)) }
        else { continuation?.yield(.finished(ScanSnapshot(items: 3,bytes: 4096,elapsed: 1,errors: partial ? 1 : 0,cancelled: false,complete: !partial,folders: 2,currentFolder: "/fixture"))) }
        continuation?.finish(); continuation = nil
    }
    func cancel() {
        continuation?.yield(.finished(ScanSnapshot(items: 3,bytes: 4096,elapsed: 1,errors: 0,cancelled: true,complete: false,folders: 2,currentFolder: "/fixture")))
        continuation?.finish(); continuation = nil
    }
}

@MainActor struct FixedActivity: ApplicationActivityProviding {
    let paths: [String]
    func blockedCachePaths(home: String) -> [String] { paths }
}

actor InitiallyPartialScanner: ScanServing {
    private var first = true
    private let scanner = ScanCoordinator()
    func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent> {
        let stream = await scanner.scan(request,into: index)
        guard first else { return stream }
        first = false
        return AsyncStream { continuation in
            Task {
                for await event in stream {
                    if case .finished(let result) = event {
                        continuation.yield(.finished(ScanSnapshot(items: result.items,bytes: result.bytes,elapsed: result.elapsed,errors: result.errors,cancelled: true,complete: false,folders: result.folders,currentFolder: result.currentFolder)))
                    } else { continuation.yield(event) }
                }
                continuation.finish()
            }
        }
    }
    func cancel() async { await scanner.cancel() }
}
