import Foundation

public enum CleanupMode: Sendable { case trash, permanent }

/// What removing a queued entry does to the filesystem.
public enum CleanupOperation: Sendable, Hashable {
    /// Delete the item itself (and, for folders, everything below it).
    case remove
    /// Delete the folder's current contents while keeping the folder itself.
    case emptyContents
}

/// One diagnostics event a cleanup run emits while executing, in order. The app
/// persists these beyond the returned results so a post-mortem log shows exactly
/// which paths failed and why — including inner failures of an emptied folder, which
/// the aggregate result message counts but cannot name.
public enum CleanupEvent: Sendable {
    /// An entry entered the executing plan with its operation.
    case itemQueued(path: String, operation: String)
    /// An exact entry was removed or a folder was emptied in place.
    case itemSucceeded(path: String, message: String)
    /// An exact entry (preflight refusal, validation, or filesystem error) failed.
    case itemFailed(path: String, message: String)
    /// One child of an emptied folder stayed in place with the stated reason.
    case childFailed(parent: String, path: String, message: String)
}

/// One reviewed deletion-queue entry: the scanned node plus what its removal means.
public struct CleanupEntry: Sendable, Identifiable, Equatable {
    public let node: FileNode
    public let operation: CleanupOperation
    /// For a duplicate copy: the copy that must still exist, unchanged, for this one to
    /// be removed. Cleanup refuses the removal otherwise, so a set never loses every copy.
    public let survivor: Survivor?
    public var id: Int64 { node.id }
    public init(node: FileNode, operation: CleanupOperation, survivor: Survivor? = nil) {
        self.node = node; self.operation = operation; self.survivor = survivor
    }

    public struct Survivor: Sendable, Equatable, Hashable {
        public let path: String
        public let identity: String
        public let fingerprint: String?
        public init(path: String, identity: String, fingerprint: String?) {
            self.path = path; self.identity = identity; self.fingerprint = fingerprint
        }
        public init(_ node: FileNode) { self.init(path: node.path, identity: node.identity, fingerprint: node.fingerprint) }
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
    /// Optional diagnostics hook receiving the run's trail while it executes, so the
    /// app can persist exactly which paths failed and why — including child failures
    /// inside emptied folders that the aggregate result message counts but cannot name.
    /// `nil` keeps execution silent.
    public let diagnostics: (@Sendable (CleanupEvent) -> Void)?
    public var root: URL { roots.first ?? URL(fileURLWithPath: "/") }
    public init(root: URL, items: [FileNode], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (String) async -> String?)? = nil, knownCacheRoots: [String] = [], diagnostics: (@Sendable (CleanupEvent) -> Void)? = nil) {
        self.init(roots: [root], items: items, mode: mode, ancestorIdentities: ancestorIdentities, preflight: preflight, knownCacheRoots: knownCacheRoots, diagnostics: diagnostics)
    }
    /// Multi-scope plans authorize candidates under every scanned root, as grouped scans do.
    public init(roots: [URL], items: [FileNode], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (String) async -> String?)? = nil, knownCacheRoots: [String] = [], diagnostics: (@Sendable (CleanupEvent) -> Void)? = nil) {
        self.init(roots: roots, entries: items.map { CleanupEntry(node: $0, operation: .remove) }, mode: mode, ancestorIdentities: ancestorIdentities, preflight: preflight, knownCacheRoots: knownCacheRoots, diagnostics: diagnostics)
    }
    /// Entries keep their per-item operation; the same containment rules apply.
    public init(roots: [URL], entries: [CleanupEntry], mode: CleanupMode, ancestorIdentities: [String: String] = [:], preflight: (@Sendable (String) async -> String?)? = nil, knownCacheRoots: [String] = [], diagnostics: (@Sendable (CleanupEvent) -> Void)? = nil) {
        self.preflight = preflight
        self.roots = roots.map(canonicalURL)
        self.mode = mode
        self.ancestorIdentities = ancestorIdentities
        self.knownCacheRoots = knownCacheRoots
        self.diagnostics = diagnostics
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
