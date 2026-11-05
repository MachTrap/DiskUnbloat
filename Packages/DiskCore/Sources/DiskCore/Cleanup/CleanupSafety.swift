import Foundation
import Synchronization

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
        return protectionReason(path: path, packageAncestor: node.packageAncestor, isPackage: node.isPackage, url: node.url, exemptingCacheRoots: exemptingCacheRoots)
    }
    /// Scan-root folders cannot be removed, but they can be queued to empty their contents
    /// while the folder itself stays. Only exact scan-root folders qualify; "/" and volume
    /// roots remain refused, and the managed-data, package, and system protections still
    /// apply to the folder — its contents inherit them because those rules are prefix-closed.
    public static func emptyContentsBlockedReasonCode(_ node: FileNode, roots: [URL], exemptingCacheRoots: [String] = []) -> CleanupReason? {
        let path = node.path
        let scopePaths = roots.map { canonicalURL($0).path }
        guard !scopePaths.isEmpty else { return .outsideScope }
        guard scopePaths.contains(where: { path.isWithin($0) }) else { return .outsideScope }
        guard scopePaths.contains(path), path != "/" else { return .scanRoot }
        guard node.isDirectory, !node.isSymbolicLink else { return .scanRoot }
        return protectionReason(path: path, packageAncestor: node.packageAncestor, isPackage: node.isPackage, url: node.url, exemptingCacheRoots: exemptingCacheRoots)
    }
    /// Shared tail of both checks: curated cache locations (and their contents) may be
    /// cleaned; their managed parents and every other managed tree stay protected.
    private static func protectionReason(path: String, packageAncestor: Bool, isPackage: Bool, url: URL, exemptingCacheRoots: [String]) -> CleanupReason? {
        let knownCache = exemptingCacheRoots.contains { path.isWithin($0) }
        if !knownCache, isManagedData(path) { return .managedData }
        if packageAncestor { return .packageContents }
        let protected = ["/System", "/Library", "/bin", "/sbin", "/usr", "/dev", "/etc", "/var", "/private/etc", "/private/var/db", "/private/var/root", "/private/var/vm", "/private/var/log", "/Applications", "/System/Volumes/Data/System", "/System/Volumes/Data/Library"]
        // Regular third-party app bundles the user (or an installer) placed directly
        // inside /Applications are ordinary removable applications — macOS itself still
        // refuses anything Apple pins system-wide (and zero-byte failures are reported
        // per item). Everything else under /Applications — the Applications folder
        // itself, /Applications/Utilities with the Apple/qualifying mix, grouping
        // folders, and all nested content — stays protected.
        if protected.contains(where: { path.isWithin($0) }) {
            guard isRemovableThirdPartyApp(path: path, isPackage: isPackage, insidePackage: packageAncestor) else { return .systemManaged }
        }
        // Mount table lookup, never a per-path resource query: asking Foundation about a
        // protected media folder (e.g. ~/Movies/TV) raises its consent dialog, and this
        // check runs for every map tile.
        if MountPoints.contains(path) { return .volumeRoot } // index paths are canonical already
        return nil
    }
    /// A direct `.app` package child of `/Applications` is a regular user application.
    private static func isRemovableThirdPartyApp(path: String, isPackage: Bool, insidePackage: Bool) -> Bool {
        guard isPackage, !insidePackage, path.hasSuffix(".app") else { return false }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Applications"
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


/// Mounted volume roots from `getmntinfo`, cached briefly (the mount table rarely changes).
enum MountPoints {
    private static let cache = Mutex<(paths: Set<String>, read: Date)>((paths: [], read: .distantPast))

    static func contains(_ path: String) -> Bool {
        cache.withLock { state in
            if Date().timeIntervalSince(state.read) > 5 { state = (current(), Date()) }
            return state.paths.contains(path)
        }
    }

    static func current() -> Set<String> {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return ["/"] }
        var paths: Set<String> = []
        for index in 0..<Int(count) {
            var entry = mounts[index]
            let path = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            paths.insert(path)
        }
        return paths
    }
}
