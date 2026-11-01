import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct MapFirstFlowTests {
    @Test func completedScanOpensCleanupQueueWithMap() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        #expect(model.phase == .choosing)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan()
        #expect(model.phase == .scanning)
        #expect(!model.canClean)
        await scanner.ready()
        await scanner.finish()
        await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.explorer.scene.summary.knownBytes == 4096)
        // The cleanup queue opens itself once a scan completes.
        #expect(model.cleanup.showQueue)
        #expect(model.cleanup.basket.isEmpty)
        #expect(model.canClean)
        await model.shutdown()
    }

    @Test func cancelledScanRequiresOptInForPartialMapAndDisablesCleanup() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready()
        model.cancel(); await model.waitForScan()
        #expect(model.phase == .cancelled)
        #expect(!model.canClean)
        #expect(!model.cleanup.showQueue)
        model.viewPartialMap(); await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(!model.canClean)
        #expect(!model.cleanup.showQueue)
        await model.shutdown()
    }

    @Test func completedPartialScanStillOpensKnownMap() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready(); await scanner.finish(partial: true); await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.scan.snapshot?.complete == false)
        #expect(model.explorer.scene.summary.knownBytes == 4096)
        await model.shutdown()
    }

    @Test func failureCanRetryWithoutShowingAnEmptyExplorer() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready()
        await scanner.finish(error: "Test failure"); await model.waitForScan()
        if case .failed = model.phase {} else { Issue.record("Failure must have a dedicated screen") }
        model.startScan(); await scanner.ready()
        await scanner.finish(); await model.waitForScan()
        #expect(model.phase == .exploring)
        await model.shutdown()
    }

    @Test func selectionTotalsDoNotDoubleCountParentAndChild() async throws {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready(); await scanner.finish(); await model.waitForScan()
        model.explorer.selectionIDs = [2,3]
        #expect(model.explorer.normalizedSelection.map(\.id) == [2])
        #expect(model.explorer.selectionBytes == 4096)
        let geometryBefore = model.explorer.scene
        model.explorer.highlightedCategory = .video
        #expect(model.explorer.scene == geometryBefore)
        await model.shutdown()
    }

    @Test func quickTargetsUseSuppliedRealHomeAndDropsRejectFiles() throws {
        let catalog = LocationCatalog(home: URL(fileURLWithPath: "/Users/tester"))
        #expect(catalog.targets.first?.url.path == "/Users/tester")
        #expect(catalog.targets.first { $0.id == "downloads" }?.url.path == "/Users/tester/Downloads")
        #expect(catalog.additional.map(\.url.path) == ["/Users/tester/Documents","/Users/tester/Pictures"])
        #expect(catalog.targets.first { $0.id == "xcode" }?.url.path == "/Users/tester/Library/Developer/Xcode/DerivedData")
        // Grouped quick actions stack several known locations under one synthetic map root.
        let caches = try #require(catalog.targets.first { $0.id == "allCaches" })
        let tools = try #require(catalog.targets.first { $0.id == "devTools" })
        #expect(caches.grouped && tools.grouped)
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Caches")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Code - Insiders/WebStorage")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/.npm/_cacache")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/Xcode/iOS DeviceSupport")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/CoreSimulator/Devices")))
        let homeTarget = try #require(catalog.targets.first { $0.id == "home" })
        #expect(!homeTarget.grouped && homeTarget.roots == [homeTarget.url])
        let model = LocationSelectionViewModel(catalog: catalog)
        #expect(throws: (any Error).self) { try model.directory(from: []) }
        #expect(throws: (any Error).self) { try model.directory(from: [URL(string: "https://example.com")!]) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try model.directory(from: [file]) }
    }
}
