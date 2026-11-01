import Foundation

public enum CleanupMode: Sendable { case trash, permanent }

/// What removing a queued entry does to the filesystem.
public enum CleanupOperation: Sendable, Hashable {
    /// Delete the item itself (and, for folders, everything below it).
    case remove
    /// Delete the folder's current contents while keeping the folder itself.
    case emptyContents
}

/// One reviewed deletion-queue entry: the scanned node plus what its removal means.
public struct CleanupEntry: Sendable, Identifiable, Equatable {
    public let node: FileNode
    public let operation: CleanupOperation
    public var id: Int64 { node.id }
    public init(node: FileNode, operation: CleanupOperation) {
        self.node = node; self.operation = operation
    }
}

public struct CleanupPlan: Sendable {
    public let roots: [URL]
    public let items: [CleanupEntry]
    public let mode: CleanupMode
    /// Per-mutation guard rechecked before every removal by path (e.g. running-app caches).
    public let preflight: (@Sendable (String) async -> String?)?
    public let ancestorIdentities: [String: String]
    /// Curated cache locations allowed through the managed-data protection for this plan.
    public let knownCacheRoots: [String]
    public var root: URL { roots.first ?? URL(fileURLWithPath: "/") }
    public init(root: URL, items: [FileNode], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (String) async -> String?)? = nil, knownCacheRoots: [String] = []) {
        self.init(roots: [root], items: items, mode: mode, ancestorIdentities: ancestorIdentities, preflight: preflight, knownCacheRoots: knownCacheRoots)
    }
    /// Multi-scope plans authorize candidates under every scanned root, as grouped scans do.
    public init(roots: [URL], items: [FileNode], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (String) async -> String?)? = nil, knownCacheRoots: [String] = []) {
        self.init(roots: roots, entries: items.map { CleanupEntry(node: $0, operation: .remove) }, mode: mode, ancestorIdentities: ancestorIdentities, preflight: preflight, knownCacheRoots: knownCacheRoots)
    }
    /// Entries keep their per-item operation; the same containment rules apply.
    public init(roots: [URL], entries: [CleanupEntry], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (String) async -> String?)? = nil, knownCacheRoots: [String] = []) {
        self.preflight = preflight
        self.roots = roots.map(canonicalURL)
        self.mode = mode
        self.ancestorIdentities = ancestorIdentities
        self.knownCacheRoots = knownCacheRoots
        let sorted = entries.sorted { $0.node.path < $1.node.path }
        var normalized: [CleanupEntry] = []
        for item in sorted {
            // Lexical order visits a directory's descendants before the next sibling, so the
            // last kept path is the only possible ancestor of the next item. Any queued
            // operation inside a kept entry is subsumed by it: removing a folder deletes its
            // contents, and emptying a folder deletes everything except the folder itself.
            guard let last = normalized.last else { normalized.append(item); continue }
            if item.node.path == last.node.path {
                // The same folder queued twice keeps the stronger operation: removal.
                if item.operation == .remove { normalized[normalized.count - 1] = item }
                continue
            }
            if item.node.path.isWithin(last.node.path) { continue }
            normalized.append(item)
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
