import Foundation

public enum CleanupMode: Sendable { case trash, permanent }
public struct CleanupPlan: Sendable {
    public let roots: [URL]
    public let items: [FileNode]
    public let mode: CleanupMode
    public let preflight: (@Sendable (FileNode) async -> String?)?
    public let ancestorIdentities: [String: String]
    /// Curated cache locations allowed through the managed-data protection for this plan.
    public let knownCacheRoots: [String]
    public var root: URL { roots.first ?? URL(fileURLWithPath: "/") }
    public init(root: URL, items: [FileNode], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (FileNode) async -> String?)? = nil, knownCacheRoots: [String] = []) {
        self.init(roots: [root], items: items, mode: mode, ancestorIdentities: ancestorIdentities, preflight: preflight, knownCacheRoots: knownCacheRoots)
    }
    /// Multi-scope plans authorize candidates under every scanned root, as grouped scans do.
    public init(roots: [URL], items: [FileNode], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (FileNode) async -> String?)? = nil, knownCacheRoots: [String] = []) {
        self.preflight = preflight
        self.roots = roots.map(canonicalURL)
        self.mode = mode
        self.ancestorIdentities = ancestorIdentities
        self.knownCacheRoots = knownCacheRoots
        let sorted = items.sorted { $0.path < $1.path }
        var normalized: [FileNode] = []
        var ancestor: String?
        for item in sorted {
            // Lexical order visits a directory's descendants before the next sibling, so the
            // last kept path is the only possible ancestor of the next item.
            if let ancestor, item.path == ancestor || item.path.hasPrefix(ancestor + "/") { continue }
            normalized.append(item); ancestor = item.path
        }
        self.items = normalized
    }
}
public struct CleanupResult: Sendable, Identifiable {
    public let id: Int64
    public let path: String
    public let succeeded: Bool
    public let message: String
    public init(id: Int64, path: String, succeeded: Bool, message: String) {
        self.id = id; self.path = path; self.succeeded = succeeded; self.message = message
    }
}
