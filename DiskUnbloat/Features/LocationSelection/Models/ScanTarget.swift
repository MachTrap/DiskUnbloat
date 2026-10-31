import Foundation
import Darwin

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
    /// Known cache locations in the real home folder; hashed Telegram group container is
    /// part of the curated cleanup rule, so quick scans keep the same exact set.
    private var cacheRoots: [URL] {
        [
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            home.appendingPathComponent("Library/Application Support/Unreal Tournament/Cache"),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"),
            home.appendingPathComponent("Library/Application Support/Code - Insiders/WebStorage"),
            home.appendingPathComponent("Library/Application Support/Code - Insiders/agent-host/sdk-cache"),
            home.appendingPathComponent("Library/Application Support/Code - Insiders/CachedExtensionVSIXs"),
            home.appendingPathComponent("Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"),
            home.appendingPathComponent(".cache/uv"),
            home.appendingPathComponent(".npm/_cacache"),
            home.appendingPathComponent(".gradle/caches")
        ]
    }
    /// Locations that hold heavy developer artifacts: simulators, device support records,
    /// SDKs, container/VM disk images, and local model stores. Missing ones are skipped.
    private var devToolRoots: [URL] {
        [
            home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"),
            home.appendingPathComponent("Library/Developer/CoreSimulator/Devices"),
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
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
