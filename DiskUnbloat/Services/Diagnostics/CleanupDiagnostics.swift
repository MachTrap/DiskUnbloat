import Foundation
import DiskCore

/// What the workspace persists about one cleanup run, so a post-mortem shows
/// exactly what was queued and what went wrong — including running-application
/// refusals decided before the plan executes. Sniffing failures out of the
/// on-screen report alone is not enough once the report is gone.
protocol CleanupDiagnosticRecording: Sendable {
    /// One run begins with its mode, scopes, and the queue as it was submitted.
    func runStarted(mode: CleanupMode, roots: [String], items: [(path: String, operation: String)])
    /// A queued item was refused before the plan executed (e.g. running-application caches).
    func refused(path: String, message: String)
    /// A core execution event: queued, succeeded, failed, or a stayed-in-place child.
    func event(_ event: CleanupEvent)
    /// The run's outcome summary, after results are collected.
    func runFinished(succeeded: Int, failed: Int)
}

/// No-op recorder for tests and previews: diagnostics never touch the filesystem.
struct NullCleanupDiagnostics: CleanupDiagnosticRecording {
    func runStarted(mode: CleanupMode, roots: [String], items: [(path: String, operation: String)]) {}
    func refused(path: String, message: String) {}
    func event(_ event: CleanupEvent) {}
    func runFinished(succeeded: Int, failed: Int) {}
}

/// App-only OS adapter: appends one JSON line per event to
/// `~/Library/Logs/DiskUnbloat/cleanup.log` (an unindexed log location
/// Console.app already bundles, requiring no extra entitlement). Writes are
/// serialized on a private queue; write failures are swallowed — diagnostics
/// must never break a cleanup run.
final class CleanupDiagnosticsService: CleanupDiagnosticRecording, @unchecked Sendable {
    private let queue = DispatchQueue(label: "DiskUnbloat.cleanupDiagnostics", qos: .utility)
    let fileURL: URL
    private let formatter = ISO8601DateFormatter()

    init(fileURL: URL? = nil) {
        let directory = fileURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: ("~/Library/Logs/DiskUnbloat" as NSString).expandingTildeInPath)
        self.fileURL = fileURL ?? directory.appendingPathComponent("cleanup.log")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func runStarted(mode: CleanupMode, roots: [String], items: [(path: String, operation: String)]) {
        append([
            "event": "run_started",
            "mode": String(describing: mode),
            "items": String(items.count),
            "roots": roots.joined(separator: " | "),
            "queue": items.map { "\(String(describing: $0.operation)) \($0.path)" }.joined(separator: " | "),
        ])
    }

    func refused(path: String, message: String) {
        append(["event": "item_refused", "path": path, "message": message])
    }

    func event(_ event: CleanupEvent) {
        switch event {
        case .itemQueued(let path, let operation):
            append(["event": "item_queued", "operation": operation, "path": path])
        case .itemSucceeded(let path, let message):
            append(["event": "item_succeeded", "path": path, "message": message])
        case .itemFailed(let path, let message):
            append(["event": "item_failed", "path": path, "message": message])
        case .childFailed(let parent, let path, let message):
            append(["event": "child_failed", "parent": parent, "path": path, "message": message])
        }
    }

    func runFinished(succeeded: Int, failed: Int) {
        append(["event": "run_finished", "succeeded": String(succeeded), "failed": String(failed)])
    }

    /// One line, one object: the first append creates the file. The write is synchronous
    /// so a run's audit trail is complete the moment `runFinished` returns — the run's
    /// events are few, and a lost tail would defeat the log's purpose.
    private func append(_ object: [String: String]) {
        queue.sync {
            var line = object
            line["time"] = self.formatter.string(from: Date())
            guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            data.append(Data("\n".utf8))
            if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                FileManager.default.createFile(atPath: self.fileURL.path, contents: data)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: self.fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
