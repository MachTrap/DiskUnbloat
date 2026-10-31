import AppKit
import DiskCore

@MainActor protocol ApplicationActivityProviding: Sendable {
    func blockedCachePaths(home: String) -> [String]
}

@MainActor struct ApplicationActivityService: ApplicationActivityProviding {
    func blockedCachePaths(home: String) -> [String] {
        let identifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var paths = identifiers.map { home + "/Library/Caches/" + $0 }
        // Xcode Derived Data is intentionally not blocked here: it is regenerable build output
        // (a curated cleanup target), so old entries stay removable while Xcode runs — worst
        // case Xcode rebuilds them. Other running-app caches below remain protected.
        // App-owned cache paths (VS Code, Chrome) are derived from the curated cleanup rule so
        // the blocklist can never drift from the known cache locations.
        let userCaches = CleanupRule.userCaches.roots(relativeTo: home).map(\.path)
        if identifiers.contains("com.microsoft.VSCodeInsiders") {
            paths += userCaches.filter { $0.contains("/Code - Insiders/") }
        }
        if identifiers.contains("com.google.Chrome") { paths += userCaches.filter { $0.contains("/Google/Chrome/") } }
        if let identifier = Bundle.main.bundleIdentifier { paths.append(home + "/Library/Caches/" + identifier) }
        if let cache = FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask).first { paths.append(cache.appendingPathComponent("Scans").path) }
        paths += [home + "/Library/Caches/com.diskunbloat.app", home + "/Library/Caches/com.apple.CloudKit", home + "/Library/Caches/CloudKit"]
        return paths
    }
}
