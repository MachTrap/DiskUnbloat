import AppKit
import Foundation
import os

/// In-memory trail of what the app did, for a report the user saves or copies and sends
/// themselves. Nothing is uploaded. Entries mirror to the unified log under the
/// `diagnostics` category. Bounded, so a long session cannot grow it without limit.
@MainActor final class DiagnosticsLog {
    struct Entry: Sendable { let date: Date; let category: String; let message: String }
    private(set) var entries: [Entry] = []
    private let capacity: Int
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DiskUnbloat", category: "diagnostics")

    init(capacity: Int = 400) { self.capacity = capacity }

    func record(_ category: String, _ message: String) {
        entries.append(Entry(date: Date(), category: category, message: message))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        logger.info("\(category, privacy: .public): \(message, privacy: .private)")
    }

    /// Plain-text report: environment, permission state, the trail, and the cleanup log tail.
    func report(fullDiskAccess: Bool, cleanupLog: URL? = CleanupDiagnosticsService.logURL) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var architecture = utsname(); uname(&architecture)
        let machine = withUnsafeBytes(of: &architecture.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let stamp = ISO8601DateFormatter()
        var lines = [
            "DiskUnbloat diagnostics — \(stamp.string(from: Date()))",
            "App: \(version) (\(build)) · \(Bundle.main.bundleIdentifier ?? "?")",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString) · \(machine) · \(ProcessInfo.processInfo.activeProcessorCount) cores",
            "Full Disk Access: \(fullDiskAccess ? "granted" : "not granted")",
            "Locale: \(Locale.current.identifier)",
            "",
            "Events (\(entries.count), oldest first):",
        ]
        lines += entries.map { "\(stamp.string(from: $0.date))  [\($0.category)] \($0.message)" }
        if let cleanupLog, let text = try? String(contentsOf: cleanupLog, encoding: .utf8) {
            lines += ["", "Cleanup log (last 200 lines):"] + text.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).map(String.init)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Copies or saves a diagnostics report; the save panel is the user's explicit choice of destination.
@MainActor enum DiagnosticsExport {
    static func copy(_ report: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    static func save(_ report: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DiskUnbloat Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}
