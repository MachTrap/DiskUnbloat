import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Regression: a home scan, the rebuildable quick-select confirmed, and the map ending
/// up completely empty ("No sized items") although only part of the scan (about half the
/// bytes) was queued. Root causes were a SQLite expression-depth rejection of the map
/// query's long exclusion list and an honest-accounting gap around collapsed containers.
@MainActor @Suite(.serialized) struct MapAfterSelectionTests {
    private func discard(_ index: ScanIndex) async {
        let url = index.url
        await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// A realistic developer home: caches, several projects with rebuildable folders,
    /// documents, downloads, and media, so quick selection covers a real share of bytes.
    private func fixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapRepro-home-" + UUID().uuidString, isDirectory: true)
        for relative in [
            "Library/Caches/com.big/cache.pack",
            "Library/Caches/com.other/cache.pack",
            "Documents/project/keep.doc",
            "Downloads/archive-2020.zip",
            "Movies/render.mov",
            "Music/song.mp3",
            "Pictures/photo.raw",
            "CODE/one/node_modules/left.js",
            "CODE/one/node_modules/deep/right.js",
            "CODE/two/node_modules/lib.js",
            "CODE/two/.build/artifacts.o",
            "CODE/three/Pods/Realm.framework",
            "go/pkg/mod/cache/download/module.zip",
        ] {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: url)
        }
        return home
    }

    @Test func rebuildableSelectionNeverEmptiesTheMap() async throws {
        let home = canonicalURL(try fixtureHome())
        defer { try? FileManager.default.removeItem(at: home) }
        let indexURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let index = try ScanIndex(url: indexURL)
        defer { Task { await discard(index) } }
        let stream = await ScanCoordinator().scan(ScanRequest(root: home, options: ScanOptions()), into: index)
        var snapshot: ScanSnapshot?
        for await event in stream {
            if case .finished(let s) = event { snapshot = s }
            if case .failed(let error) = event { Issue.record("scan failed: \(error)") }
        }
        #expect(snapshot?.complete == true)

        // The explorer shows the finished home scan at its root.
        let model = ExplorerViewModel(settings: SettingsViewModel())
        await model.attach(index, options: ScanOptions())
        #expect(model.scene.summary.knownBytes > 0)
        let before = model.scene.summary.knownBytes

        // Tier-2 selection over the real index, applied like the workspace does it.
        let result = await index.autoSelectionCandidates(
            home: home.path, tier: .regenerable, unusedDays: 30)
        #expect(!result.isEmpty)
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: home.path, activity: FixedActivity(paths: []))
        let outcome = cleanup.applyAutoSelection(result, roots: [home])
        #expect(outcome.applied > 0)
        #expect(outcome.skipped == 0)
        let queuedBytes = cleanup.estimatedBytes
        #expect(queuedBytes > 0)
        // Sanity: the queue is a minority of the scan, as the user reported (53 of 135 GB).
        #expect(queuedBytes < before)

        // Queue paths reach the explorer exactly as the workspace forwards them.
        await model.updateHiddenPaths(cleanup.basket.map { $0.node.path })
        try await Task.sleep(for: .milliseconds(320))
        // The map keeps every unqueued root with exact visible bytes, and the header
        // total loses only the queue's own estimate — never more, never less.
        #expect(model.scene.summary.knownBytes == before - queuedBytes)
        #expect(!model.scene.entries.isEmpty)
        #expect(model.scene.entries.contains { $0.bytes > 0 })
        #expect(try #require(model.scene.entries.first { $0.node?.name == "CODE" })!.bytes > 0)
        // Every top-level folder outside the queue keeps its positive visible size.
        for name in ["Documents", "Downloads", "Movies", "Music", "Pictures"] {
            #expect(try #require(model.scene.entries.first { $0.node?.name == name })!.bytes > 0)
        }
    }

    /// The workspace forwards queue mutations into the explorer itself, never relying
    /// on a SwiftUI `.onChange` relay for the handoff (which never fired in the field).
    @Test func queueChangesReachTheExplorerFromTheModel() throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cleanup = CleanupViewModel(service: RecordingCleanupService(), homePath: home.path, activity: FixedActivity(paths: []))
        var hidden: [String] = []
        cleanup.basketDidUpdate = { entries in hidden = entries.map { $0.node.path } }
        let caches = canonicalURL(home).appendingPathComponent("Library/Caches")
        let node = FileNode(id: 7, parentID: nil, path: caches.path,
                            name: "Caches", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "7")
        #expect(cleanup.add(node, roots: [home]) == nil)
        #expect(hidden == [node.path])
        cleanup.clearSelection()
        #expect(hidden.isEmpty)
    }

    /// Full workspace flow: scan, the rebuildable quick-select through `selectItems`
    /// (which mutates the queue), and the map reactively re-rendered with the queued
    /// bytes removed. Uses a queue of over a thousand entries — the bulk scale that
    /// once blanked the map — inside the real home so the regenerable name rules can
    /// match (their query excludes the system trees, temp dirs included).
    @Test func workspacesQuickSelectUpdatesTheMapThroughTheQueue() async throws {
        // Inside ~/Library/Caches: readable without privileges, yet outside the protected
        // trees (Application Support) that the regenerable name query deliberately skips.
        let host = LocationCatalog().home
            .appendingPathComponent("Library/Caches/DiskUnbloatMapFlowTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let scanned = canonicalURL(host)
        defer { try? FileManager.default.removeItem(at: scanned) }
        // 1100 node_modules folders — each an entire candidate the regenerable tier
        // queues — plus a kept source file per tree, so count and bytes both scale.
        for tree in 0..<1100 {
            let nodeModules = scanned.appendingPathComponent("CODE/tree\(tree)/node_modules/pkg/file.bin")
            try FileManager.default.createDirectory(at: nodeModules.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: 4096).write(to: nodeModules)
            let source = scanned.appendingPathComponent("CODE/tree\(tree)/src/main.swift")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 2048).write(to: source)
        }
        for relative in ["Documents/keep.doc", "Movies/render.mov", "Music/song.mp3", "Pictures/photo.raw"] {
            let url = scanned.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: url)
        }
        let suite = "DiskUnbloatMapFlowTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceViewModel(authorization: AuthorizationStore(defaults: defaults, bookmarks: StubBookmarkAccess(url: scanned)), fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = scanned
        model.startScan(); await model.waitForScan()
        guard case .exploring = model.phase else {
            Issue.record("expected exploring, got \(model.phase)"); await model.shutdown(); return
        }
        let before = model.explorer.scene.summary.knownBytes
        #expect(before > 0)
        model.selectItems(.regenerable)
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(100))
            if !model.selectingItems { break }
        }
        await model.waitForScan()
        // Allow the debounced map refresh plus the asynchronous hidden-range coalescing.
        try await Task.sleep(for: .milliseconds(1200))
        let explorer = model.explorer
        try await Task.sleep(for: .milliseconds(2000))
        #expect(explorer.hiddenPaths.count >= 1000)
        #expect(!explorer.scene.entries.isEmpty)
        let top = explorer.scene.entries.filter { $0.ownerID == explorer.scene.rootID }
        #expect(top.contains { $0.node?.name == "Documents" && $0.bytes > 0 })
        // Every node_modules is gone from the map; each tree's kept source remains.
        #expect(try #require(top.first { $0.node?.name == "CODE" }).bytes == 1100 * 4096)
        #expect(model.cleanup.basket.count == 1100)
        #expect(explorer.scene.summary.knownBytes == before - model.cleanup.estimatedBytes)
        await model.shutdown()
    }
}
