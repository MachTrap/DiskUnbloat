import AppKit
import DiskCore

@MainActor protocol ApplicationActivityProviding: Sendable {
    func blockedCachePaths(home: String) -> [String]
}

@MainActor struct ApplicationActivityService: ApplicationActivityProviding {
    func blockedCachePaths(home: String) -> [String] {
        let identifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var paths = identifiers.map { home + "/Library/Caches/" + $0 }
        if identifiers.contains("com.apple.dt.Xcode") { paths.append(home + "/Library/Developer/Xcode/DerivedData") }
        if identifiers.contains("com.microsoft.VSCodeInsiders") {
            paths += [home + "/Library/Application Support/Code - Insiders/WebStorage",
                      home + "/Library/Application Support/Code - Insiders/agent-host/sdk-cache",
                      home + "/Library/Application Support/Code - Insiders/CachedExtensionVSIXs"]
        }
        if identifiers.contains("com.google.Chrome") { paths.append(home + "/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel") }
        if let identifier = Bundle.main.bundleIdentifier { paths.append(home + "/Library/Caches/" + identifier) }
        if let cache = FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask).first { paths.append(cache.appendingPathComponent("Scans").path) }
        paths += [home + "/Library/Caches/com.diskunbloat.app", home + "/Library/Caches/com.apple.CloudKit", home + "/Library/Caches/CloudKit"]
        return paths
    }
}
