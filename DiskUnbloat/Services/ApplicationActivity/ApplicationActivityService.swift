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
        // Curated caches of third-party apps that live outside ~/Library/Caches/<id>, keyed by
        // their owning bundle ID; paths resolve from the cleanup rule so they can't drift.
        let appOwnedCaches: [(owner: String, marker: String)] = [
            ("com.microsoft.VSCodeInsiders", "/Code - Insiders/"),
            ("com.google.Chrome", "/Google/Chrome/"),
        ]
        for entry in appOwnedCaches where identifiers.contains(entry.owner) {
            paths += userCaches.filter { $0.contains(entry.marker) }
        }
        if let identifier = Bundle.main.bundleIdentifier { paths.append(home + "/Library/Caches/" + identifier) }
        if let cache = FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask).first { paths.append(cache.appendingPathComponent("Scans").path) }
        paths += [home + "/Library/Caches/com.diskunbloat.app", home + "/Library/Caches/com.apple.CloudKit", home + "/Library/Caches/CloudKit"]
        return paths
    }
}
