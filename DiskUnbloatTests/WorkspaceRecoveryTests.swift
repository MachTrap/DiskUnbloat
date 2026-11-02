import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// The scan-failure recovery path: the failed screen names the underlying refusal and
/// offers re-authorization through the picker (a macOS Files-and-Folders denial is
/// recorded by the system and repeating the same scan can never revive it).
@MainActor struct WorkspaceRecoveryTests {
    @Test func scanFailureNamesTheUnderlyingRefusal() async throws {
        let model = WorkspaceViewModel()
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
        let model = WorkspaceViewModel()
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
