import Foundation

public enum ScanStage: String, Sendable, CaseIterable {
    case reading = "Reading files"
    case aggregating = "Calculating folder sizes"
    case preparingMap = "Preparing map"
}
public struct ScanSnapshot: Sendable {
    public let items: Int
    public let bytes: Int64
    public let elapsed: TimeInterval
    public let errors: Int
    public let cancelled: Bool
    public let complete: Bool
    public let folders: Int
    public let currentFolder: String
    public init(items: Int, bytes: Int64, elapsed: TimeInterval, errors: Int, cancelled: Bool, complete: Bool, folders: Int = 0, currentFolder: String = "") {
        self.items = items; self.bytes = bytes; self.elapsed = elapsed; self.errors = errors
        self.cancelled = cancelled; self.complete = complete; self.folders = folders; self.currentFolder = currentFolder
    }
}
public enum ScanEvent: Sendable {
    case stage(ScanStage)
    case progress(ScanSnapshot)
    case finished(ScanSnapshot)
    case failed(String)
    /// The upfront preflight touched macOS-protected directories whose opens were refused
    /// — protected app data (other applications' data, media libraries, mail and messages).
    /// The system offers no consent dialog for these reads; full measurement needs the
    /// user's Full Disk Access decision, so the UI explains that instead of a raw error list.
    case protectedFoldersRefused
}

public struct ScanIssue: Sendable {
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}
