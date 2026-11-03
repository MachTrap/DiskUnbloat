import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Times the quick-select pipeline at bulk scale: coalescing, map scene commit, and the
/// cleanup queue panel rebuild ("Updating the list…") that the user saw spinning for
/// minutes. Each phase prints its timing so the optimization targets are measurable.
@MainActor @Suite(.serialized) struct QueuePerformanceBench {
    private func discard(_ index: ScanIndex) async {
        let url = index.url
        await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private func makeClock() -> ContinuousClock { ContinuousClock() }

    @Test func timesEachStageAtFieldScale() async throws {
        let clock = makeClock()
        func since(_ start: ContinuousClock.Instant) -> String {
            let d = clock.now - start
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            return String(format: "%.0fms", ms)
        }

        // --- Build the fixture: like a real home tree (deep paths, ~1650 queued entries,
        // plus filler files so the index is not tiny).
        let t0 = clock.now
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerfBench-" + UUID().uuidString, isDirectory: true)
        for path in [
            "Library/Caches/com.big/cache.pack", "Library/Caches/com.other/cache.pack",
            "Documents/project/keep.doc", "Downloads/archive-2020.zip",
            "Movies/render.mov", "Music/song.mp3", "Pictures/photo.raw",
        ] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: url)
        }
        // fill the filesystem as: 1643 individually queued entries (debris folders) with 8 filler files each.
        for item in 0..<1643 {
            let base = home.appendingPathComponent("CODE/p\(item % 60)/proj\(item/60)-\(item)/node_modules/leaf-\(item)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 2048).write(to: base.appendingPathComponent("artifact.o"))
        }
        // filler: 30k files to lift the index to a field-scale row count
        for f in 0..<30000 {
            let url = home.appendingPathComponent("DATA/bench\(f % 300)/f-\(f)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1024).write(to: url)
        }
        print("BENCH fixture \(since(t0))")
        let scanned = canonicalURL(home)
        defer { try? FileManager.default.removeItem(at: scanned) }

        // --- Scan
        let t1 = clock.now
        let index = try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        defer { Task { await discard(index) } }
        let stream = await ScanCoordinator().scan(ScanRequest(root: scanned, options: ScanOptions()), into: index)
        for await event in stream { if case .failed(let e) = event { Issue.record("\(e)") } }
        print("BENCH scan \(since(t1))")

        // --- Explorer attach (baseline map scene)
        let model = ExplorerViewModel(settings: SettingsViewModel())
        let t2 = clock.now
        await model.attach(index, options: ScanOptions())
        print("BENCH attach \(since(t2))")

        // --- A field-scale basket: 1643 individually queued folders collected straight
        // from index rows (the regenerable-name query excludes the /var fixture tree in
        // tests, so candidates are materialized directly).
        let t3 = clock.now
        var gather = FileQuery()
        gather.subtreePath = scanned.path + "/CODE"
        var queued: [FileNode] = []
        while true {
            let page = await index.query(gather)
            queued += page.filter { $0.isDirectory && $0.name == "node_modules" }
            if page.count < gather.limit { break }
            gather.offset += page.count
        }
        print("BENCH basket-gather \(since(t3)) entries=\(queued.count)")
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: scanned.path, activity: FixedActivity(paths: []))
        var updatedHidden: [String] = []
        cleanup.basketDidUpdate = { entries in updatedHidden = entries.map { $0.node.path } }
        let t4 = clock.now
        cleanup.basket = CleanupPlan(roots: [scanned], items: queued, mode: .trash).items
        print("BENCH applyAutoSelection \(since(t4)) basket=\(cleanup.basket.count)")

        // --- Coalesced hidden ranges (runs on the index actor)
        let t5 = clock.now
        let ranges = await index.coalescedHiddenRanges(for: cleanup.basket.map { $0.node.path })
        print("BENCH coalescedHiddenRanges \(since(t5)) paths=\(ranges.paths.count) subtrees=\(ranges.subtrees.count)")

        // --- Map scene commit with hidden state applied (what the explorer reload does)
        var sceneQuery = FileQuery(); sceneQuery.parentID = 1
        sceneQuery.hiddenPaths = ranges.paths; sceneQuery.hiddenSubtrees = ranges.subtrees
        var clean = FileQuery(); clean.parentID = 1
        let t6a = clock.now
        _ = await index.query(clean)
        print("BENCH root query(clean) \(since(t6a))")
        let t6b = clock.now
        _ = await index.summary(clean)
        print("BENCH root summary \(since(t6b))")
        let t6c = clock.now
        _ = await index.categoryList(sceneQuery)
        print("BENCH legend categoryList \(since(t6c))")
        var leaf = FileQuery(); leaf.leafResults = true
        let t6d = clock.now
        _ = await index.summary(leaf)
        print("BENCH leaf summary \(since(t6d))")
        let t6 = clock.now
        let scene = await index.mapScene(rootID: 1, query: sceneQuery, filtered: false)
        print("BENCH mapScene(withHidden) \(since(t6)) entries=\(scene.entries.count)")

        // --- The queue panel refresh (the "Updating the list…" spinner)
        let queue = CleanupQueueModel(cleanup: cleanup)
        let provider = IndexCleanupQueueProvider(index: index, inspectPackages: false)
        queue.attach(provider)
        let root = try #require(await index.node(1))
        let t7 = clock.now
        await queue.refresh(current: root)
        print("BENCH queue.refresh #1 \(since(t7)) lines=\(queue.lines.count)")
        for attempt in 1...3 {
            let start = clock.now
            await queue.refresh(current: root)
            print("BENCH queue.refresh repeat \(attempt) \(since(start))")
        }
        let t9 = clock.now
        let queuedPaths = cleanup.basket.map { $0.node.path }
        for line in queue.lines {
            if case .item(let row) = line {
                _ = queueMembership(path: row.node.path, queuedPaths: queuedPaths)
            }
        }
        print("BENCH membership-for-all-lines \(since(t9))")
        let _ = updatedHidden
    }

    private func wait(_ d: Duration) async throws { try await Task.sleep(for: d) }
}
