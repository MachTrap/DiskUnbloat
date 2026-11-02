import Foundation
import DiskCore

extension CleanupRule {
    var title: String {
        switch self {
        case .large: L10n.text("Large files")
        case .downloads: L10n.text("Old downloads")
        case .archives: L10n.text("Old archives and installers")
        case .userCaches: L10n.text("User & application caches")
        case .derivedData: L10n.text("Xcode Derived Data")
        case .swiftPM: L10n.text("SwiftPM cache")
        case .npm: L10n.text("npm cache")
        case .pip: L10n.text("pip cache")
        case .regenerable: L10n.text("Regenerable folders")
        }
    }
    var explanation: String {
        switch self {
        case .large: L10n.text("These files exceed your size threshold. Size does not establish that they are unused.")
        case .downloads: L10n.text("Downloads older than your threshold may still contain important documents. Review each item.")
        case .archives: L10n.text("Old archives and installers may be needed for recovery or offline installation.")
        case .userCaches: L10n.text("Old cache data from ~/Library/Caches and known application cache locations, including Xcode build data, device support, simulators, and messenger caches. The most recent device support stays. Removal can disrupt applications and require re-downloading data.")
        case .derivedData: L10n.text("Old Xcode build intermediates. Removal requires rebuilding your projects.")
        case .swiftPM: L10n.text("Old cached Swift packages. Future builds may need to download dependencies again.")
        case .npm: L10n.text("Old npm package cache entries. Future installs may require network access.")
        case .pip: L10n.text("Old Python package downloads and wheels. Future installs may need to download them again.")
        case .regenerable: L10n.text("Folders that tools can rebuild or download again, such as node_modules, Pods, DerivedData, .next, .cache, __pycache__, or local build output. Excluded entries stay untouched. Rebuilds and re-downloads take time.")
        }
    }
    /// Curated cache locations exempt from managed-data protection for this home.
    static func knownCacheRoots(home: String) -> [String] {
        guard !home.isEmpty else { return [] }
        return CleanupRule.allCases.flatMap { $0.roots(relativeTo: home) }.map(\.path)
    }
}
