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
    public init(root: URL, options: ScanOptions = .init()) { self.root = root; self.options = options }
}
