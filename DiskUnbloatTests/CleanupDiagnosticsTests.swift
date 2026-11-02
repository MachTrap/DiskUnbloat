import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// The persisted cleanup audit trail: a run's queue, refusals, outcomes, and inner
/// child failures land in the JSON-lines log of the diagnostics service, so a
/// post-mortem shows exactly what was queued and what went wrong.
@MainActor struct CleanupDiagnosticsTests {
    @Test func cleanupRunPersistsQueueAndOutcomes() async throws {
        let outer = canonicalURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("DiskUnbloatDiag-" + UUID().uuidString)
        let scope = outer.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outer) }
        let disposable = scope.appendingPathComponent("allowed.bin")
        try Data([1]).write(to: disposable)
        let indexURL = outer.appendingPathComponent("index.sqlite")
        let index = try ScanIndex(url: indexURL)

        let identity = try FileIdentity.read(disposable)
        let fileNode = FileNode(id: 2, parentID: nil, path: disposable.path, name: disposable.lastPathComponent,
                                isDirectory: false, logicalSize: identity.size, allocatedSize: identity.allocated,
                                modified: identity.modified, identity: identity.identity)
        let diagnostics = CleanupDiagnosticsService(fileURL: outer.appendingPathComponent("cleanup.log"))
        let model = CleanupViewModel(service: CleanupService(), homePath: outer.path,
                                     activity: FixedActivity(paths: []), diagnostics: diagnostics)
        #expect(model.add(fileNode, roots: [scope]) == nil)
        let items = try #require(model.begin())
        #expect(await model.execute(items, roots: [scope], index: index, mode: .permanent))
        #expect(!FileManager.default.fileExists(atPath: disposable.path))
        await index.close()

        let lines = diagnosticsLines(of: diagnostics.fileURL)
        #expect(lines.compactMap { $0["event"] } == ["run_started", "item_queued", "item_succeeded", "run_finished"])
        #expect(lines[0]["mode"] == "permanent")
        #expect(lines[0]["roots"] == scope.path)
        #expect(lines[0]["queue"] == "remove \(disposable.path)")
        #expect(lines[2]["path"] == disposable.path)
        #expect(lines.last?["succeeded"] == "1" && lines.last?["failed"] == "0")
    }

    @Test func everyEventKindMapsToItsLogLine() async throws {
        let directory = canonicalURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("DiskUnbloatDiag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = CleanupDiagnosticsService(fileURL: directory.appendingPathComponent("cleanup.log"))
        // The app-side frames and every core event kind serialize to one line each.
        diagnostics.runStarted(mode: .trash, roots: ["/scope"], items: [
            (path: "/scope/a.bin", operation: "remove"),
            (path: "/scope/b.cache", operation: "emptyContents"),
        ])
        diagnostics.refused(path: "/scope/b.cache", message: "refusal reason")
        diagnostics.event(.itemQueued(path: "/scope/a.bin", operation: "remove"))
        diagnostics.event(.itemSucceeded(path: "/scope/a.bin", message: "Moved to Trash"))
        diagnostics.event(.itemFailed(path: "/scope/c.bin", message: "changed since scanning"))
        diagnostics.event(.childFailed(parent: "/scope/emptied", path: "/scope/emptied/stuck.bin", message: "failed"))
        diagnostics.runFinished(succeeded: 1, failed: 2)

        let lines = diagnosticsLines(of: diagnostics.fileURL)
        #expect(lines.compactMap { $0["event"] } == [
            "run_started", "item_refused", "item_queued", "item_succeeded", "item_failed", "child_failed", "run_finished",
        ])
        #expect(lines[0]["items"] == "2")
        #expect(lines[1]["path"] == "/scope/b.cache" && lines[1]["message"] == "refusal reason")
        #expect(lines[5]["parent"] == "/scope/emptied" && lines[5]["path"] == "/scope/emptied/stuck.bin")
        #expect(lines.last?["succeeded"] == "1" && lines.last?["failed"] == "2")
        // Every line is timestamped.
        #expect(lines.allSatisfy { $0["time"]?.isEmpty == false })
    }

    /// Parses one JSON object per line from the log file.
    private func diagnosticsLines(of url: URL) -> [[String: String]] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line -> [String: String]? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }
}
