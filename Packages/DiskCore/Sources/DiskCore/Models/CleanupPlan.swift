import Foundation

public enum CleanupMode: Sendable { case trash, permanent }
public struct CleanupPlan: Sendable {
    public let root: URL
    public let items: [FileNode]
    public let mode: CleanupMode
    public let preflight: (@Sendable (FileNode) async -> String?)?
    public let ancestorIdentities: [String: String]
    /// Curated cache locations allowed through the managed-data protection for this plan.
    public let knownCacheRoots: [String]
    public init(root: URL, items: [FileNode], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (FileNode) async -> String?)? = nil, knownCacheRoots: [String] = []) {
        self.preflight = preflight
        self.root = canonicalURL(root)
        self.mode = mode
        self.ancestorIdentities = ancestorIdentities
        self.knownCacheRoots = knownCacheRoots
        let sorted = items.sorted { $0.path.count < $1.path.count }
        var normalized: [FileNode] = []
        for item in sorted where !normalized.contains(where: { item.path == $0.path || item.path.hasPrefix($0.path + "/") }) { normalized.append(item) }
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
