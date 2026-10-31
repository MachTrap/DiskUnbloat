import Foundation
import Darwin
import DiskCore

struct ScanTarget: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let detail: String
    let url: URL
    let developer: Bool
    /// Grouped quick actions scan multiple known locations under one synthetic map root.
    let extra: [URL]
    init(id: String, title: String, symbol: String, detail: String, url: URL, developer: Bool, extra: [URL] = []) {
        self.id = id; self.title = title; self.symbol = symbol; self.detail = detail
        self.url = url; self.developer = developer; self.extra = extra
    }
    var roots: [URL] { [url] + extra }
    var grouped: Bool { !extra.isEmpty }
}
struct LocationCatalog {
    let home: URL
    init(home: URL? = nil) {
        if let home { self.home = home; return }
        // Foundation's default home/search paths can point inside the sandbox container.
        var record = passwd(); var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16384)
        let path = buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(getuid(), &record, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let directory = record.pw_dir else { return nil }
            return String(cString: directory)
        }
        self.home = URL(fileURLWithPath: path ?? NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory(), isDirectory: true)
    }
    /// Known cache locations in the real home folder, derived from the curated cleanup rule so
    /// quick scans and cleanup never drift apart. Device-support/simulator trees are excluded
    /// here because they group under dev tools.
    private var cacheRoots: [URL] {
        CleanupRule.userCaches.roots(relativeTo: home.path)
            .filter { $0.candidate != .childrenKeepingNewest }
            .map { URL(fileURLWithPath: $0.path) }
    }
    /// Locations that hold heavy developer artifacts. The device-support/simulator trees and
    /// DerivedData come from the cleanup rules; the rest are scan-only (not cleanup candidates).
    private var devToolRoots: [URL] {
        var urls = CleanupRule.userCaches.roots(relativeTo: home.path)
            .filter { $0.candidate == .childrenKeepingNewest }
            .map { URL(fileURLWithPath: $0.path) }
        urls.append(home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
        urls += [
            home.appendingPathComponent("Library/Android/sdk"),
            home.appendingPathComponent(".android/avd"),
            home.appendingPathComponent("Library/Containers/com.docker.docker"),
            home.appendingPathComponent("Parallels"),
            home.appendingPathComponent("Virtual Machines"),
            home.appendingPathComponent("Library/Containers/com.utmapp.UTM"),
            home.appendingPathComponent(".ollama"),
            home.appendingPathComponent(".cache/huggingface"),
            home.appendingPathComponent(".cache/lm-studio")
        ]
        return urls
    }
    var targets: [ScanTarget] {
        [
            ScanTarget(id: "home", title: L10n.text("Home folder"), symbol: "house", detail: L10n.text("The bigger picture. Explore everything you authorize in your home folder."), url: home, developer: false),
            ScanTarget(id: "downloads", title: L10n.text("Downloads"), symbol: "arrow.down.circle", detail: L10n.text("Installers, archives, and things you saved for later."), url: home.appendingPathComponent("Downloads"), developer: false),
            ScanTarget(id: "caches", title: L10n.text("User caches"), symbol: "shippingbox", detail: L10n.text("Temporary application data. Removing it can disrupt apps or require downloads."), url: home.appendingPathComponent("Library/Caches"), developer: false),
            ScanTarget(id: "allCaches", title: L10n.text("All caches"), symbol: "shippingbox", detail: L10n.text("Every known cache in your home folder in one scan: user caches, Xcode build data, developer caches, messenger media, and browser model files. Missing locations are skipped and listed during the scan."), url: cacheRoots[0], developer: false, extra: Array(cacheRoots.dropFirst())),
            ScanTarget(id: "xcode", title: L10n.text("Xcode Derived Data"), symbol: "hammer", detail: L10n.text("Build intermediates. Removal requires rebuilding your projects."), url: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), developer: true),
            ScanTarget(id: "swiftpm", title: L10n.text("SwiftPM cache"), symbol: "shippingbox", detail: L10n.text("Cached Swift packages. Packages may need to be downloaded again."), url: home.appendingPathComponent("Library/Caches/org.swift.swiftpm"), developer: true),
            ScanTarget(id: "npm", title: L10n.text("npm cache"), symbol: "curlybraces", detail: L10n.text("Cached npm packages. Future installs may need the network."), url: home.appendingPathComponent(".npm/_cacache"), developer: true),
            ScanTarget(id: "pip", title: L10n.text("pip cache"), symbol: "terminal", detail: L10n.text("Downloaded Python packages and wheels. Installs may need to download them again."), url: home.appendingPathComponent("Library/Caches/pip"), developer: true),
            ScanTarget(id: "devTools", title: L10n.text("Dev tools"), symbol: "wrench.and.screwdriver", detail: L10n.text("Heavy developer artifacts: simulators, device support, Android SDK, Docker data, virtual machines, and local AI model stores."), url: devToolRoots[0], developer: true, extra: Array(devToolRoots.dropFirst()))
        ]
    }
    var additional: [ScanTarget] {
        ["Documents", "Pictures"].map { ScanTarget(id: $0, title: $0, symbol: "folder", detail: "", url: home.appendingPathComponent($0), developer: false) }
    }
}
