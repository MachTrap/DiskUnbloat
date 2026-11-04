import Testing
import Foundation
@testable import DiskCore

/// Read-only throughput comparison on a real folder, enabled with
/// `DISKUNBLOAT_BENCH_PATH=/some/folder swift test --filter ScanThroughputBench`.
/// "legacy" replays the previous single-threaded walk (FileManager enumerator, one lstat
/// and one resource-value lookup per item); the others drain the parallel bulk engine
/// without an index, so only enumeration cost is compared.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DISKUNBLOAT_BENCH_PATH"] != nil))
struct ScanThroughputBench {
    @Test func compareEnumerationStrategies() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DISKUNBLOAT_BENCH_PATH"]))
        _ = legacy(root) // warm the metadata cache so every strategy reads from memory
        let legacyRun = measure { legacy(root) }
        var options = ScanOptions(); options.summarizedFolders = []
        let oneWorker = await measureAsync { await drain(root, options, workers: 1) }
        let parallel = await measureAsync { await drain(root, options, workers: ParallelEnumeration.defaultWorkerCount) }
        let summarized = await measureAsync { await drain(root, ScanOptions(), workers: ParallelEnumeration.defaultWorkerCount) }
        print("BENCH legacy        \(legacyRun.items) items \(legacyRun.seconds)s")
        print("BENCH bulk×1        \(oneWorker.items) items \(oneWorker.seconds)s")
        print("BENCH bulk×\(ParallelEnumeration.defaultWorkerCount)        \(parallel.items) items \(parallel.seconds)s")
        print("BENCH bulk×\(ParallelEnumeration.defaultWorkerCount)+summary \(summarized.items) items \(summarized.seconds)s")
    }

    private func legacy(_ root: URL) -> Int {
        let keys: [URLResourceKey] = [.isPackageKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            guard let identity = try? FileIdentity.read(url) else { enumerator.skipDescendants(); continue }
            _ = try? url.resourceValues(forKeys: Set(keys))
            if identity.link { enumerator.skipDescendants() }
            else if identity.directory { _ = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) }
            count += 1
        }
        return count
    }
    private func drain(_ root: URL, _ options: ScanOptions, workers: Int) async -> Int {
        let engine = ParallelEnumeration(ScanRequest(root: root, options: options), workers: workers)
        defer { engine.cancel() }
        var count = 0
        while true { let batch = await engine.next(); count += batch.nodes.count; if batch.done { return count } }
    }
    private func measure(_ body: () -> Int) -> (items: Int, seconds: String) {
        let start = Date(); let items = body()
        return (items, String(format: "%.2f", Date().timeIntervalSince(start)))
    }
    private func measureAsync(_ body: () async -> Int) async -> (items: Int, seconds: String) {
        let start = Date(); let items = await body()
        return (items, String(format: "%.2f", Date().timeIntervalSince(start)))
    }
}
