import Foundation

public struct ScanOptions: Sendable, Codable {
    public var includeHidden = true
    public var inspectPackages = false
    public var crossVolumes = false
    public var exclusions: [String] = []
    public init() {}
}
public struct ScanRequest: Sendable {
    /// Preserve the caller's security-scoped URL. Canonical paths are for indexing, not authorization.
    public let root: URL
    public let options: ScanOptions
    /// Grouped quick actions scan several known locations in one pass, stacked under a
    /// synthetic wrapper node identified by `ScanGroup.path`.
    public let extraRoots: [URL]
    /// Localized label of the synthetic wrapper node; empty for plain single-root scans.
    public let groupTitle: String
    public var roots: [URL] { [root] + extraRoots }
    /// Convenience initializer for single-root scans; extra roots are absent, so the
    /// credentials and user interface can keep depending on `root` alone.
    public init(root: URL, options: ScanOptions = .init()) { self.init(root: root, extraRoots: [], groupTitle: "", options: options) }
    public init(root: URL, extraRoots: [URL], groupTitle: String, options: ScanOptions = .init()) {
        self.root = root; self.extraRoots = extraRoots; self.options = options; self.groupTitle = groupTitle
    }
}

/// Identity of the synthetic parent node that groups multiple scan roots into one map.
/// The wrapper is never backed by a filesystem path, so real paths stay untouched.
public enum ScanGroup: Sendable, Hashable {
    public static let path = "diskunbloat:scan-group"
}

extension FileNode {
    /// Whether the node is the synthetic parent that groups multiple scan roots.
    public var isGroupRoot: Bool { path == ScanGroup.path }
}
