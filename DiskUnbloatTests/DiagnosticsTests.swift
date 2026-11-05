import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// The diagnostics report is what a tester sends back instead of a screenshot: it must
/// carry the environment, the scan trail including consent waits, and stay bounded.
@MainActor struct DiagnosticsTests {
    @Test func reportCarriesEnvironmentTrailAndCleanupLogTail() throws {
        let log = DiagnosticsLog(capacity: 3)
        for index in 1...5 { log.record("scan", "event \(index)") }
        #expect(log.entries.map(\.message) == ["event 3", "event 4", "event 5"])
        let cleanupLog = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: cleanupLog) }
        try "line a\nline b\n".write(to: cleanupLog, atomically: true, encoding: .utf8)
        let report = log.report(fullDiskAccess: false, cleanupLog: cleanupLog)
        #expect(report.contains("macOS: "))
        #expect(report.contains("Full Disk Access: not granted"))
        #expect(report.contains("[scan] event 5") && !report.contains("event 1"))
        #expect(report.contains("Cleanup log (last 200 lines):") && report.contains("line b"))
    }

    @Test func scanTrailRecordsStagesConsentWaitsAndOutcome() async {
        actor SlowConsentScanner: ScanServing {
            func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent> {
                AsyncStream { continuation in
                    Task {
                        continuation.yield(.stage(.reading))
                        continuation.yield(.awaitingPermission("/Users/someone/Desktop"))
                        try? await Task.sleep(for: .milliseconds(650))
                        continuation.yield(.awaitingPermission(nil))
                        continuation.yield(.finished(ScanSnapshot(items: 0, bytes: 0, elapsed: 1, errors: 0, cancelled: false, complete: true)))
                        continuation.finish()
                    }
                }
            }
            func cancel() {}
            func skipPermissionPreflight() {}
        }
        let model = WorkspaceViewModel(coordinator: SlowConsentScanner(), fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan()
        await model.waitForScan()
        let messages = model.diagnostics.entries.map(\.message)
        #expect(messages.contains { $0.hasPrefix("Started /fixture") })
        #expect(messages.contains { $0.hasPrefix("Stage: Reading files") })
        #expect(messages.contains { $0.hasPrefix("Waited ") && $0.hasSuffix(" on Desktop") })
        #expect(messages.contains { $0.hasPrefix("Finished") })
        await model.shutdown()
    }
}
