import Foundation
import Darwin
import AppKit

/// Answers whether macOS currently grants the app Full Disk Access, without showing
/// any dialog. Reading a `SystemPolicyAllFiles`-protected directory succeeds only with
/// the grant; from a non-interactive context tccd denies silently, so this check never
/// pops a prompt of its own and never blocks — the app's own offer UI explains the
/// decision instead.
protocol FullDiskAccessChecking: Sendable {
    func isGranted() async -> Bool
}

struct SystemFullDiskAccessProbe: FullDiskAccessChecking {
    /// FDA-protected directories that exist on essentially every macOS installation;
    /// the first existing one decides. If none exists the answer is "granted" — an
    /// unmeasurable check must never block or nag.
    private static let candidates = [
        NSHomeDirectory() + "/Library/Safari",
        NSHomeDirectory() + "/Library/Mail",
        "/Library/Application Support/com.apple.TCC",
    ]

    func isGranted() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            for path in Self.candidates where FileManager.default.fileExists(atPath: path) {
                guard let dir = opendir(path) else { return false }
                closedir(dir)
                return true
            }
            return true
        }.value
    }
}

/// Opens the exact Full Disk Access pane; both the pre-scan offer and the issues-sheet
/// card lead here.
enum FullDiskAccessSettings {
    static let paneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        ?? URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane")

    static func open() {
        NSWorkspace.shared.open(paneURL)
    }
}
