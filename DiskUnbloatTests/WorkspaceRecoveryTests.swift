import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Sandbox-grant recovery: a stale or silently failed grant makes a scan fail before
/// its first row; the repair tries the narrowest covering stored bookmark headlessly
/// (never a panel mid-scan flow), keeps the failed screen actionable with the recorded
/// issue, and prefers the home grant over a broad volume-root bookmark.
@MainActor struct WorkspaceRecoveryTests {
    /// A unique fixture directory under the real home, so the repair gate applies.
    private func homeFixture() throws -> URL {
        let directory = LocationCatalog().home
            .appendingPathComponent("Library/Application Support/DiskUnbloatRecoveryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func store(for stub: StubBookmarkAccess) -> AuthorizationStore {
        let defaults = UserDefaults(suiteName: "DiskUnbloatRecoveryTests-" + UUID().uuidString)!
        defaults.removePersistentDomain(forName: "DiskUnbloatRecoveryTests-" + UUID().uuidString)
        let suggestions = Box<URL>(nil)
        let authorization = AuthorizationStore(defaults: defaults, bookmarks: stub)
        authorization.panelProvider = { suggested, _ in suggestions.value = suggested; return nil }
        return authorization
    }

    @Test func unreadableHomeScopeRestoresItsCoveringBookmarkAutomatically() async throws {
        let scope = try homeFixture()
        defer { try? FileManager.default.removeItem(at: scope) }
        let stub = StubBookmarkAccess(url: scope)
        let authorization = store(for: stub)
        try await authorization.acceptSelection(scope)
        // The remembered grant covers the scope; drop the live access to reproduce the
        // broken-grant state, then scan a location that no longer resolves.
        authorization.release()
        let missing = scope.appendingPathComponent("gone-subfolder")
        let panels = Box<URL>(nil)
        authorization.panelProvider = { suggested, _ in panels.value = suggested; return nil }
        let model = WorkspaceViewModel(authorization: authorization, fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = missing
        model.startScan(); await model.waitForScan()
        // The repair went through the stored bookmark without any panel...
        #expect(stub.started.contains(scope))
        #expect(panels.value == nil)
        // ...and the unfixed scan still lands on the honest failure screen with the
        // underlying refusal (the recorded issue names the missing location).
        guard case .failed(let message) = model.phase else {
            Issue.record("Expected the failed phase, got \(model.phase)"); await model.shutdown(); return
        }
        #expect(message.contains(missing.lastPathComponent))
        await model.shutdown()
    }

    @Test func coveringLocationPrefersTheHomeGrantOverVolumeRoot() async throws {
        // '/' covers everything, but its activation does not reliably extend the
        // sandbox into protected home data; the most specific covering bookmark wins.
        let stub = StubBookmarkAccess(url: LocationCatalog().home)
        let authorization = store(for: stub)
        try await authorization.acceptSelection(URL(fileURLWithPath: "/"))
        await authorization.waitForPendingBookmark()
        try await authorization.acceptSelection(LocationCatalog().home)
        await authorization.waitForPendingBookmark()
        let homeChild = LocationCatalog().home.appendingPathComponent("Library/Caches")
        let covered = authorization.coveringLocation(for: [homeChild])
        #expect(covered?.name == LocationCatalog().home.path)
        #expect(authorization.coveringLocation(for: [URL(fileURLWithPath: "/tmp")])?.name == "/")
    }

    @Test func scanFailureNamesTheUnderlyingRefusal() async throws {
        let model = WorkspaceViewModel(fullDiskAccess: GrantedFullDiskAccess())
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloat-missing-" + UUID().uuidString)
        model.scan.pendingRoot = missing
        model.startScan(); await model.waitForScan()
        guard case .failed(let message) = model.phase else {
            Issue.record("Expected the failed phase, got \(model.phase)")
            await model.shutdown(); return
        }
        // The composed message keeps the base hint and adds the scan's first issue,
        // which names the location and the actual macOS refusal.
        #expect(message.contains(missing.lastPathComponent))
        await model.shutdown()
    }

    @Test func reauthorizeSuggestsTheFailedRootThroughThePicker() async throws {
        let model = WorkspaceViewModel(fullDiskAccess: GrantedFullDiskAccess())
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloat-missing-" + UUID().uuidString)
        model.scan.pendingRoot = missing
        model.startScan(); await model.waitForScan()
        guard case .failed = model.phase else {
            Issue.record("Expected the failed phase"); await model.shutdown(); return
        }
        let suggestions = Box<URL>(nil)
        model.authorization.panelProvider = { suggested, _ in suggestions.value = suggested; return nil }
        model.reauthorize()
        #expect(suggestions.value?.path == missing.path)
        guard case .failed = model.phase else { Issue.record("Declining the picker keeps the failed phase"); return }
        await model.shutdown()
    }

    final class Box<T> { var value: T?; init(_ value: T? = nil) { self.value = value } }
}
