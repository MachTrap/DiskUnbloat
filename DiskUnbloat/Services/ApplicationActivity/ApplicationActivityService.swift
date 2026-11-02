import AppKit
import DiskCore

@MainActor protocol ApplicationActivityProviding: Sendable {
    func blockedCachePaths(home: String) -> [String]
}

@MainActor struct ApplicationActivityService: ApplicationActivityProviding {
    /// Curated caches of third-party apps that live outside ~/Library/Caches/<id>, paired
    /// with the base of their owning bundle ID. A running versioned identifier such as
    /// `com.adobe.AfterEffects.26` still matches its base owner through `isOwned`, so an
    /// app update cannot silently disable the guard.
    static let appOwnedCaches: [(owner: String, marker: String)] = [
        ("com.microsoft.VSCodeInsiders", "/Code - Insiders/"),
        ("com.microsoft.VSCode", "/Code/"),
        ("com.todesktop.230313mzl4w4u92", "/Cursor/"),
        ("com.exafunction.windsurf", "/Windsurf/"),
        ("com.google.Chrome", "/Google/Chrome/"),
        // The Adobe video suite shares the Common media cache; Media Encoder also idle-runs
        // as a background queue while another app exports.
        ("com.adobe.Premiere.Pro", "/Adobe/Common/"),
        ("com.adobe.AfterEffects", "/Adobe/Common/"),
        ("com.adobe.mediaencoder", "/Adobe/Common/"),
        ("com.adobe.Audition", "/Adobe/Common/"),
        // Message-app stores: Telegram Desktop's curated cache paths (the per-account
        // postbox media) arrive as cached media being written while it runs.
        ("ru.keepcoder.Telegram", "/6N38VWS5BX.ru.keepcoder.Telegram/"),
        // Game engines and image generators hold their caches in Application Support:
        // the shared DDC store writes while any Epic-owned app runs, Godot writes while
        // the editor or an exported run is open, and Comfy Desktop holds its Chromium
        // cache beside the ComfyUI service.
        ("com.epicgames", "/Epic/"),
        ("org.godotengine", "/Godot/"),
        ("com.todesktop.241012ess7yxs0e", "/Comfy Desktop/"),
    ]

    /// Ownership match: the exact identifier, or the owner followed by a segmented
    /// continuation (`.`, `-`) so a versioned product id stays owned by its base.
    /// `com.microsoft.VSCodeInsiders` therefore never matches `com.microsoft.VSCode`.
    static func isOwned(_ running: String, owner: String) -> Bool {
        running == owner || running.hasPrefix(owner + ".") || running.hasPrefix(owner + "-")
    }

    func blockedCachePaths(home: String) -> [String] {
        let identifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var paths = identifiers.map { home + "/Library/Caches/" + $0 }
        // Xcode Derived Data is intentionally not blocked here: it is regenerable build output
        // (a curated cleanup target), so old entries stay removable while Xcode runs — worst
        // case Xcode rebuilds them. Other running-app caches below remain protected.
        // App-owned cache paths are derived from the curated cleanup rule so the blocklist
        // can never drift from the known cache locations.
        let userCaches = CleanupRule.userCaches.roots(relativeTo: home).map(\.path)
        for (owner, marker) in Self.appOwnedCaches where identifiers.contains(where: { Self.isOwned($0, owner: owner) }) {
            paths += userCaches.filter { $0.contains(marker) }
        }
        if let identifier = Bundle.main.bundleIdentifier { paths.append(home + "/Library/Caches/" + identifier) }
        if let cache = FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask).first { paths.append(cache.appendingPathComponent("Scans").path) }
        paths += [home + "/Library/Caches/com.diskunbloat.app", home + "/Library/Caches/com.apple.CloudKit", home + "/Library/Caches/CloudKit"]
        return paths
    }
}
