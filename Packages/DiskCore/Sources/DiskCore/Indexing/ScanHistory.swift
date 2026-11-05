import Foundation

/// What a finished scan leaves behind for comparing growth later: sizes of its largest
/// items by path, never contents. Small enough to keep several per scope.
public struct ScanHistorySnapshot: Codable, Sendable, Equatable {
    /// Identifies the scope: the scan roots, canonical and sorted.
    public let rootKey: String
    public let date: Date
    public let totalBytes: Int64
    /// Known on-disk bytes by path, for items at or above `minimumBytes`.
    public let sizes: [String: Int64]
    public let minimumBytes: Int64
    /// The scan had unreadable locations; its sizes are lower bounds.
    public let partial: Bool

    public init(rootKey: String, date: Date, totalBytes: Int64, sizes: [String: Int64], minimumBytes: Int64, partial: Bool) {
        self.rootKey = rootKey; self.date = date; self.totalBytes = totalBytes
        self.sizes = sizes; self.minimumBytes = minimumBytes; self.partial = partial
    }

    public static func rootKey(_ roots: [URL]) -> String { roots.map { canonicalURL($0).path }.sorted().joined(separator: "\n") }

    /// Earlier size of `path`, or what can honestly be said without one: `nil` when the
    /// item is new (absent although big enough to have been recorded).
    public func previousBytes(of path: String, current: Int64) -> Int64? {
        if let bytes = sizes[path] { return bytes }
        // Below the recording floor then and now: treat as unchanged small item.
        return current < minimumBytes ? current : nil
    }
}

extension ScanIndex {
    /// Largest items (files and folders) by known on-disk size, at least `minimumBytes`.
    public func historySizes(minimumBytes: Int64, limit: Int = 20_000) -> [String: Int64] {
        let rows = read("SELECT * FROM nodes WHERE parent IS NOT NULL AND knownAllocated>=\(max(1, minimumBytes)) ORDER BY knownAllocated DESC LIMIT \(max(1, limit))")
        return Dictionary(rows.map { ($0.path, $0.knownSize(for: .allocated)) }, uniquingKeysWith: { first, _ in first })
    }

    public func historySnapshot(roots: [URL], partial: Bool, minimumBytes: Int64 = 1 << 20, date: Date = Date()) -> ScanHistorySnapshot? {
        guard let root = node(1) else { return nil }
        return ScanHistorySnapshot(rootKey: ScanHistorySnapshot.rootKey(roots), date: date, totalBytes: root.knownSize(for: .allocated),
                                   sizes: historySizes(minimumBytes: minimumBytes), minimumBytes: minimumBytes, partial: partial)
    }
}
