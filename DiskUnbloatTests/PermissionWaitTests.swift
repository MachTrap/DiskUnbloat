import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// The scanning screen while macOS consent dialogs are pending: it knows which folder it
/// waits on, forwards Skip to the coordinator, and a cancel before anything was read
/// returns to the chooser instead of reporting an unreadable location.
@MainActor struct PermissionWaitTests {
    actor WaitingScanner: ScanServing {
        private var continuation: AsyncStream<ScanEvent>.Continuation?
        private(set) var skipped = false
        func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent> {
            AsyncStream { continuation in
                self.continuation = continuation
                continuation.yield(.stage(.reading))
                continuation.yield(.awaitingPermission("/Users/friend/Desktop"))
            }
        }
        func skipPermissionPreflight() { skipped = true; continuation?.yield(.awaitingPermission(nil)) }
        func cancel() {
            continuation?.yield(.awaitingPermission(nil))
            continuation?.yield(.finished(ScanSnapshot(items: 0, bytes: 0, elapsed: 1, errors: 0, cancelled: true, complete: false)))
            continuation?.finish(); continuation = nil
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func pendingConsentIsVisibleSkippableAndCancelReturnsToTheChooser() async {
        let scanner = WaitingScanner()
        let model = WorkspaceViewModel(coordinator: scanner, fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan()
        await waitUntil { model.scan.awaitingPermission != nil }
        #expect(model.phase == .scanning)
        #expect(model.scan.awaitingPermission == "/Users/friend/Desktop")
        await model.scan.skipPermissionRequests()
        #expect(await scanner.skipped)
        await waitUntil { model.scan.awaitingPermission == nil }
        #expect(model.scan.awaitingPermission == nil)
        model.cancel()
        await model.waitForScan()
        // Nothing was read: not a failure of the location, just back to choosing.
        #expect(model.phase == .choosing)
        await model.shutdown()
    }
}
