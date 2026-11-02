import Foundation
import Darwin
import DiskCore

struct ScanTarget: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let detail: String
    let url: URL
    /// Grouped quick actions scan multiple known locations under one synthetic map root.
    let extra: [URL]
    init(id: String, title: String, symbol: String, detail: String, url: URL, extra: [URL] = []) {
        self.id = id; self.title = title; self.symbol = symbol; self.detail = detail
        self.url = url; self.extra = extra
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
    /// The chooser's quick actions: one flat list of equal-size pills. The individual
    /// developer-cache targets are gone — their locations are already covered by
    /// "All caches"; developer artifacts live behind the grouped "Dev tools" action.
    var targets: [ScanTarget] {
        [
            ScanTarget(id: "home", title: L10n.text("Home folder"), symbol: "house", detail: L10n.text("The bigger picture. Explore everything you authorize in your home folder."), url: home),
            ScanTarget(id: "downloads", title: L10n.text("Downloads"), symbol: "arrow.down.circle", detail: L10n.text("Installers, archives, and things you saved for later."), url: home.appendingPathComponent("Downloads")),
            ScanTarget(id: "caches", title: L10n.text("User caches"), symbol: "shippingbox", detail: L10n.text("Temporary application data. Removing it can disrupt apps or require downloads."), url: home.appendingPathComponent("Library/Caches")),
            ScanTarget(id: "allCaches", title: L10n.text("All caches"), symbol: "shippingbox", detail: L10n.text("Every known cache in your home folder in one scan: user caches, Xcode build data, developer caches, messenger media, and browser model files. Missing locations are skipped and listed during the scan."), url: cacheRoots[0], extra: Array(cacheRoots.dropFirst())),
            ScanTarget(id: "devTools", title: L10n.text("Dev tools"), symbol: "wrench.and.screwdriver", detail: L10n.text("Heavy developer artifacts: simulators, device support, Android SDK, Docker data, virtual machines, and local AI model stores."), url: devToolRoots[0], extra: Array(devToolRoots.dropFirst()))
        ]
    }
    var additional: [ScanTarget] {
        ["Documents", "Pictures"].map { ScanTarget(id: $0, title: $0, symbol: "folder", detail: "", url: home.appendingPathComponent($0)) }
    }
}
