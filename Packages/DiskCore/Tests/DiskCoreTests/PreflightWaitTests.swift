import Foundation
import Testing
@testable import DiskCore

/// A consent dialog nobody answers (hidden behind the window, or a stuck File Provider)
/// blocks the preflight's `opendir`. The scan must say what it waits on, and both skip and
/// cancel must get through instead of leaving an elapsed timer over zero files.
struct PreflightWaitTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("Desktop/a.bin"))
        try Data(count: 4096).write(to: root.appendingPathComponent("b.bin"))
        return root
    }
    private func index() throws -> ScanIndex {
        try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
    }
    /// A probe that never returns until released: an unanswered consent dialog.
    private func hangingCoordinator(_ root: URL, release: DispatchSemaphore) -> ScanCoordinator {
        ScanCoordinator(
            preflightTargets: { _ in [ScanPermissionPreflight.Target(url: root.appendingPathComponent("Desktop"), depth: .directoryOnly)] },
            preflightProbe: { _, _ in release.wait(); return .readable })
    }
    private func firstWait(_ events: inout AsyncStream<ScanEvent>.Iterator) async -> String? {
        while let event = await events.next() { if case .awaitingPermission(let path?) = event { return path } }
        return nil
    }

    @Test func skippingAHangingConsentProbeStillScansEverything() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let coordinator = hangingCoordinator(root, release: release)
        let db = try index()
        var events = await coordinator.scan(ScanRequest(root: root), into: db).makeAsyncIterator()
        let waiting = await firstWait(&events)
        #expect(waiting == root.appendingPathComponent("Desktop").path)
        await coordinator.skipPermissionPreflight()
        var finished: ScanSnapshot?
        var cleared = false
        while let event = await events.next() {
            if case .awaitingPermission(nil) = event { cleared = true }
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        #expect(cleared)
        // Root, Desktop, two files: nothing was lost to the skipped probe.
        #expect(finished?.items == 4 && finished?.cancelled == false)
        await db.close()
    }

    @Test func cancellingDuringAHangingConsentProbeEndsTheScan() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let coordinator = hangingCoordinator(root, release: release)
        let db = try index()
        var events = await coordinator.scan(ScanRequest(root: root), into: db).makeAsyncIterator()
        _ = await firstWait(&events)
        await coordinator.cancel()
        var finished: ScanSnapshot?
        while let event = await events.next() { if case .finished(let snapshot) = event { finished = snapshot } }
        // The stream ends although the probe is still blocked, and reports a cancellation.
        #expect(finished?.cancelled == true && finished?.items == 0)
        await db.close()
    }

    @Test func waiterResumesOnceWhenAbandonedBeforeTheBodyFinishes() async {
        let waiter = PreflightWaiter()
        let release = DispatchSemaphore(value: 0)
        async let outcome = waiter.wait { release.wait(); return .containsDeniedChildren }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.abandon()
        #expect(await outcome == nil)
        release.signal() // the late result is dropped, not resumed twice
        try? await Task.sleep(for: .milliseconds(50))
    }
}
