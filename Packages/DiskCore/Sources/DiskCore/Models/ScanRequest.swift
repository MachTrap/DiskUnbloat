import Foundation

/// How much macOS consent a scan may ask for.
public enum ConsentPolicy: String, Sendable, Codable {
    /// Full Disk Access is granted (or the full upfront preflight is wanted): every
    /// protected folder in scope is probed so its dialog appears before enumeration.
    case fullDiskAccess
    /// No Full Disk Access: the scan relies on the user's folder grant and asks for one
    /// consent only — other applications' data. Personal-data stores that would raise
    /// their own dialogs (Photos, Music, Mail, Messages, Contacts, Calendars, …) are
    /// skipped unopened and reported as needing Full Disk Access.
    case minimal
}

public struct ScanOptions: Sendable, Codable {
    public var consentPolicy: ConsentPolicy = .fullDiskAccess
    /// Home folders whose protected stores the consent policy applies to; `nil` means the
    /// real user homes. The app passes its catalog home (a generated one in tests).
    public var homePaths: [String]?
    public var includeHidden = true
    public var inspectPackages = false
    public var crossVolumes = false
    public var exclusions: [String] = []
    /// Days without a recorded content modification after which an item counts as
    /// "long-unused" for automatic selection (old simulators, local AI models). A
    /// definition parameter: it shapes selection, never enumeration.
    public var longUnusedDays = 90
    /// Folders measured as one opaque item instead of being indexed entry by entry.
    /// Entries without a slash match folder names anywhere (case-insensitive); entries
    /// with one match that absolute folder. Scan roots are never summarized.
    public var summarizedFolders: [String] = ScanOptions.defaultSummarizedFolders
    public static let defaultSummarizedFolders = [".git", "node_modules"]
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
