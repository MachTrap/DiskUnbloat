import Foundation
import Synchronization
import Testing
import DiskCore
@testable import DiskUnbloat

/// Without Full Disk Access a scan asks for at most one folder grant (the open panel,
/// which macOS treats as consent) and then scans under the minimal consent policy.
@MainActor struct MinimalPermissionFlowTests {
    actor RecordingScanner: ScanServing {
        private(set) var policies: [ConsentPolicy] = []
        func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent> {
            policies.append(request.options.consentPolicy)
            return AsyncStream { $0.yield(.finished(ScanSnapshot(items: 0, bytes: 0, elapsed: 0, errors: 0, cancelled: false, complete: true))); $0.finish() }
        }
        func cancel() {}
        func skipPermissionPreflight() {}
    }

    @Test func grantTargetIsHomeForHomeScopesAndTheCommonAncestorAbove() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(WorkspaceViewModel.folderGrantTarget(roots: [home.appendingPathComponent("Library/Caches"), home.appendingPathComponent("Documents")], home: home)?.path == "/Users/someone")
        #expect(WorkspaceViewModel.folderGrantTarget(roots: [URL(fileURLWithPath: "/Users")], home: home)?.path == "/Users")
        #expect(WorkspaceViewModel.folderGrantTarget(roots: [URL(fileURLWithPath: "/")], home: home)?.path == "/")
        // Nothing consent-gated outside the home: no grant is asked for.
        #expect(WorkspaceViewModel.folderGrantTarget(roots: [URL(fileURLWithPath: "/Applications")], home: home) == nil)
    }

    @Test func declinedFolderGrantStartsNothingAndAGrantedOneScansMinimally() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("minimal-flow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = RecordingScanner()
        let model = WorkspaceViewModel(coordinator: scanner, fullDiskAccess: MutableFullDiskAccess(granted: false), catalog: LocationCatalog(home: home))
        let panels = Mutex<[String]>([])
        var answer: URL?
        model.authorization.panelProvider = { suggested, _ in panels.withLock { $0.append(suggested?.path ?? "") }; return answer }
        model.scan.pendingRoot = home.appendingPathComponent("Documents")
        model.startScan(); await model.waitForFullDiskAccessOffer()
        model.continueWithoutFullDiskAccess()
        await model.waitForScan()
        #expect(panels.withLock { $0 } == [canonicalURL(home).path])
        #expect(!model.scan.scanning && model.phase == .choosing)
        #expect(await scanner.policies.isEmpty)

        answer = home
        model.startScan(); await model.waitForFullDiskAccessOffer()
        model.continueWithoutFullDiskAccess()
        await model.waitForScan()
        #expect(await scanner.policies == [.minimal])
        // The live grant now covers the scope: the next attempt asks nothing more.
        model.startScan(); await model.waitForFullDiskAccessOffer()
        model.continueWithoutFullDiskAccess()
        await model.waitForScan()
        #expect(panels.withLock { $0 }.count == 2)
        #expect(await scanner.policies == [.minimal, .minimal])
        await model.shutdown()
    }

    /// A later session with the remembered home pick restores it silently: the picker
    /// (whose sidebar can raise a media consent) appears once, not on every scan.
    @Test func rememberedFolderGrantSkipsThePickerInALaterSession() async throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("minimal-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: created.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        // Real homes are canonical paths; match that (the temp folder lives under /var → /private/var).
        let home = canonicalURL(created)
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults()
        let first = AuthorizationStore(defaults: defaults)
        _ = try first.acceptSelection(home)
        for _ in 0..<100 where first.locations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let scanner = RecordingScanner()
        let model = WorkspaceViewModel(authorization: AuthorizationStore(defaults: defaults), coordinator: scanner,
                                       fullDiskAccess: MutableFullDiskAccess(granted: false), catalog: LocationCatalog(home: home), defaults: isolatedDefaults())
        let panels = Mutex(0)
        model.authorization.panelProvider = { _, _ in panels.withLock { $0 += 1 }; return nil }
        model.scan.pendingRoot = home.appendingPathComponent("Documents")
        model.startScan(); await model.waitForFullDiskAccessOffer()
        model.continueWithoutFullDiskAccess()
        await model.waitForScan()
        #expect(panels.withLock { $0 } == 0)
        #expect(await scanner.policies == [.minimal])
        await model.shutdown()
    }

    @Test func grantedFullDiskAccessScansWithTheFullPolicy() async {
        let scanner = RecordingScanner()
        let model = WorkspaceViewModel(coordinator: scanner, fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await model.waitForScan()
        #expect(await scanner.policies == [.fullDiskAccess])
        await model.shutdown()
    }
}
