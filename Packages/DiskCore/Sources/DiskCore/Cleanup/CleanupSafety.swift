import Foundation

public enum CleanupSafety {
    public static func blockedReason(_ node: FileNode, root: URL, exemptingCacheRoots: [String] = []) -> String? { blockedReasonCode(node, roots: [root], exemptingCacheRoots: exemptingCacheRoots)?.message }
    public static func blockedReason(_ node: FileNode, roots: [URL], exemptingCacheRoots: [String] = []) -> String? { blockedReasonCode(node, roots: roots, exemptingCacheRoots: exemptingCacheRoots)?.message }
    public static func blockedReasonCode(_ node: FileNode, root: URL, exemptingCacheRoots: [String] = []) -> CleanupReason? { blockedReasonCode(node, roots: [root], exemptingCacheRoots: exemptingCacheRoots) }
    /// Grouped scans authorize every listed root; a candidate must sit inside one scope.
    public static func blockedReasonCode(_ node: FileNode, roots: [URL], exemptingCacheRoots: [String] = []) -> CleanupReason? {
        let path = node.path
        let scopePaths = roots.map { canonicalURL($0).path }
        if path == "/" { return .scanRoot }
        guard !scopePaths.isEmpty else { return .outsideScope }
        if scopePaths.contains(path) { return .scanRoot }
        // A "/" scope authorizes the whole scanned volume, as plain single-root scans did.
        guard scopePaths.contains(where: { path.isWithin($0) }) else { return .outsideScope }
        // Only the exact curated cache locations (and their contents) are exempt; their managed
        // parents and every other managed tree remain protected.
        let knownCache = exemptingCacheRoots.contains { path.isWithin($0) }
        if !knownCache, isManagedData(path) { return .managedData }
        if node.packageAncestor { return .packageContents }
        let protected = ["/System", "/Library", "/bin", "/sbin", "/usr", "/dev", "/etc", "/var", "/private/etc", "/private/var/db", "/private/var/root", "/private/var/vm", "/private/var/log", "/Applications", "/System/Volumes/Data/System", "/System/Volumes/Data/Library"]
        if protected.contains(where: { path.isWithin($0) }) { return .systemManaged }
        if let values = try? node.url.resourceValues(forKeys: [.isVolumeKey]), values.isVolume == true { return .volumeRoot }
        return nil
    }
    private static func isManagedData(_ path: String) -> Bool {
        // Exact volume/user roots, plus the Library root itself.
        if path == "/Users" || path == "/Volumes" || path.hasSuffix("/Library") { return true }
        // Managed application-data trees: their contents are protected, except data macOS
        // re-creates under a container's Caches directory.
        let inContainers = path.contains("/Library/Containers/")
        if inContainers && !path.contains("/Data/Library/Caches/") { return true }
        if path.hasSuffix("/Library/Containers") { return true }
        if path.contains("/Library/Group Containers/") || path.hasSuffix("/Library/Group Containers") { return true }
        if path.contains("/Library/Application Support/") || path.hasSuffix("/Library/Application Support") { return true }
        return false
    }
}

public enum CleanupReason: String, Sendable {
    case scanRoot
    case outsideScope
    case managedData
    case packageContents
    case systemManaged
    case volumeRoot
    public var message: String {
        switch self {
        case .scanRoot: "Scan roots and volume roots cannot be removed."
        case .outsideScope: "Item is outside the authorized scan location."
        case .managedData: "This location contains managed application or user data and is protected from cleanup."
        case .packageContents: "Individual package contents cannot be removed. Review the whole package instead."
        case .systemManaged: "This is a protected system-managed location."
        case .volumeRoot: "Volume roots cannot be removed."
        }
    }
}
