import Foundation
import Darwin

/// Upfront TCC permission preflight for a scan request.
///
/// When a user scans their home folder (`~`) or the root disk (`/`), depth-first directory
/// enumeration would otherwise hit TCC-protected folders (`~/Pictures/Photos Library.photoslibrary`,
/// `~/Music`, `~/Library/Photos`, `~/Library/Calendars`, `~/Desktop`, `~/Documents`, etc.)
/// gradually over several minutes, interrupting the scan with system permission prompts one by
/// one. Probing the in-scope protected directories at the very start of the scan lets macOS
/// present every required consent dialog upfront while ignoring folders outside the selected
/// scan scope.
public enum ScanPermissionPreflight: Sendable {
    public enum ProbeDepth: Sendable, Equatable {
        /// Opens the directory itself and reads a single entry (`Desktop`, `Documents`, `Downloads`).
        case directoryOnly
        /// Opens the directory, up to a few immediate child directories, and any media library
        /// bundles (`.photoslibrary`, `.musiclibrary`, `.tvlibrary`) inside it.
        case childrenAndBundles
    }

    public struct Target: Sendable, Equatable {
        public let url: URL
        public let depth: ProbeDepth
        public init(url: URL, depth: ProbeDepth) {
            self.url = url
            self.depth = depth
        }
    }

    /// Home-relative paths gated by macOS TCC services (Files & Folders, Photos, Media & Apple
    /// Music, Contacts, Calendars, Reminders, iCloud Drive, and cross-app container data),
    /// ordered so personal and media prompts appear first.
    public static let homeRelativeTargets: [(path: String, depth: ProbeDepth)] = [
        ("Desktop", .directoryOnly),
        ("Documents", .directoryOnly),
        ("Downloads", .directoryOnly),
        ("Pictures", .childrenAndBundles),
        ("Pictures/Photos Library.photoslibrary", .childrenAndBundles),
        ("Music", .childrenAndBundles),
        ("Music/Music", .childrenAndBundles),
        ("Music/Music/Music Library.musiclibrary", .childrenAndBundles),
        ("Music/iTunes", .childrenAndBundles),
        ("Movies", .childrenAndBundles),
        ("Movies/TV", .childrenAndBundles),
        ("Movies/TV/TV Library.tvlibrary", .childrenAndBundles),
        ("Public", .directoryOnly),
        ("Library/Photos", .childrenAndBundles),
        ("Library/Application Support/com.apple.avfoundation", .childrenAndBundles),
        ("Library/Application Support/AddressBook", .childrenAndBundles),
        ("Library/Calendars", .childrenAndBundles),
        ("Library/Reminders", .childrenAndBundles),
        ("Library/Mobile Documents", .childrenAndBundles),
        ("Library/Mail", .childrenAndBundles),
        ("Library/Messages", .childrenAndBundles),
        ("Library/Safari", .childrenAndBundles),
        ("Library/HomeKit", .childrenAndBundles),
        ("Library/Group Containers/group.com.apple.photolibraryd", .childrenAndBundles),
        ("Library/Group Containers/group.com.apple.calendar", .childrenAndBundles),
        ("Library/Group Containers/group.com.apple.reminders", .childrenAndBundles),
        ("Library/Group Containers/group.com.apple.notes", .childrenAndBundles),
        ("Library/Group Containers/group.com.apple.music", .childrenAndBundles),
        ("Library/Group Containers", .childrenAndBundles),
        ("Library/Containers", .childrenAndBundles),
        ("Library/Daemon Containers", .childrenAndBundles),
    ]

    private static let mediaBundleSuffixes: [String] = [
        ".photoslibrary",
        ".photoboothlibrary",
        ".musiclibrary",
        ".tvlibrary",
        ".theater",
    ]

    /// Computes the ordered list of TCC-protected directories that will be traversed by `request`.
    /// Only directories that lie within the request's roots, are not excluded, and match the
    /// volume-crossing policy are returned.
    public static func targets(for request: ScanRequest, homes: [URL]? = nil) -> [Target] {
        let rootEntries: [(path: String, device: Int32)] = ([request.root] + request.extraRoots).compactMap { url in
            let canonical = canonicalURL(url)
            guard let id = try? FileIdentity.read(canonical), id.directory, !id.link else { return nil }
            return (canonical.path, id.device)
        }
        guard !rootEntries.isEmpty else { return [] }
        let excludedPaths = request.options.exclusions.map { canonicalURL(URL(fileURLWithPath: $0)).path }

        func isIncluded(_ path: String) -> Bool {
            guard let coveringRoot = rootEntries.first(where: { path.isWithin($0.path) }) else { return false }
            guard !excludedPaths.contains(where: { path.isWithin($0) }) else { return false }
            guard let identity = try? FileIdentity.read(URL(fileURLWithPath: path)),
                  identity.directory, !identity.link else { return false }
            if !request.options.crossVolumes && identity.device != coveringRoot.device { return false }
            return true
        }

        let candidateHomes = resolvedHomes(explicit: homes, rootPaths: rootEntries.map(\.path))
        var seen = Set<String>()
        var result: [Target] = []

        func appendTarget(_ path: String, depth: ProbeDepth) {
            guard seen.insert(path).inserted, isIncluded(path) else { return }
            result.append(Target(url: URL(fileURLWithPath: path, isDirectory: true), depth: depth))
        }

        for home in candidateHomes where rootEntries.contains(where: { $0.path.overlaps(home) }) {
            for entry in homeRelativeTargets {
                appendTarget(home + "/" + entry.path, depth: entry.depth)
            }
        }

        // If the scan covers `/Volumes` (either because cross-volume traversal is enabled on `/`
        // or because `/Volumes` itself was chosen), probe mounted volumes upfront as well.
        let volumesRoot = "/Volumes"
        if rootEntries.contains(where: { volumesRoot.isWithin($0.path) }),
           let names = try? FileManager.default.contentsOfDirectory(atPath: volumesRoot) {
            for name in names.sorted() where !name.hasPrefix(".") {
                appendTarget(volumesRoot + "/" + name, depth: .directoryOnly)
            }
        }

        return result
    }

    /// Touches `target` with bounded `opendir`/`readdir` calls so macOS TCC presents any needed
    /// consent dialog immediately without enumerating the full subtree.
    public static func probe(_ target: Target, excludedPaths: [String] = []) {
        let path = target.url.path
        guard !excludedPaths.contains(where: { path.isWithin($0) }) else { return }
        guard let dir = opendir(path) else { return }
        defer { closedir(dir) }

        switch target.depth {
        case .directoryOnly:
            _ = readdir(dir)
        case .childrenAndBundles:
            var childDirectories: [String] = []
            var mediaBundles: [String] = []
            var inspected = 0
            while inspected < 64, let entry = readdir(dir) {
                let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." || name.hasPrefix(".") { continue }
                inspected += 1
                let childPath = path + "/" + name
                if excludedPaths.contains(where: { childPath.isWithin($0) }) { continue }
                guard let identity = try? FileIdentity.read(URL(fileURLWithPath: childPath)),
                      identity.directory, !identity.link else { continue }
                let lower = name.lowercased()
                if mediaBundleSuffixes.contains(where: { lower.hasSuffix($0) }) {
                    mediaBundles.append(childPath)
                } else if childDirectories.count < 2 {
                    childDirectories.append(childPath)
                }
            }
            for bundlePath in mediaBundles {
                probeMediaBundle(at: bundlePath, excludedPaths: excludedPaths)
            }
            if Self.isMediaBundlePath(path) {
                for sub in childDirectories {
                    shallowOpen(sub)
                }
            } else {
                for childPath in childDirectories {
                    shallowOpen(childPath)
                    let dataPath = childPath + "/Data"
                    if !excludedPaths.contains(where: { dataPath.isWithin($0) }),
                       let id = try? FileIdentity.read(URL(fileURLWithPath: dataPath)),
                       id.directory, !id.link {
                        shallowOpen(dataPath)
                    }
                }
            }
        }
    }

    private static func isMediaBundlePath(_ path: String) -> Bool {
        let lower = (path as NSString).lastPathComponent.lowercased()
        return mediaBundleSuffixes.contains { lower.hasSuffix($0) }
    }

    private static func probeMediaBundle(at bundlePath: String, excludedPaths: [String]) {
        guard let dir = opendir(bundlePath) else { return }
        defer { closedir(dir) }
        var inspected = 0
        while inspected < 32, let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }
            inspected += 1
            let subPath = bundlePath + "/" + name
            if excludedPaths.contains(where: { subPath.isWithin($0) }) { continue }
            if let id = try? FileIdentity.read(URL(fileURLWithPath: subPath)), id.directory, !id.link {
                shallowOpen(subPath)
            }
        }
    }

    private static func shallowOpen(_ path: String) {
        guard let dir = opendir(path) else { return }
        _ = readdir(dir)
        closedir(dir)
    }

    private static func resolvedHomes(explicit: [URL]?, rootPaths: [String]) -> [String] {
        if let explicit {
            return explicit.map { canonicalURL($0).path }
        }
        var homes: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            let canonical = canonicalURL(URL(fileURLWithPath: path)).path
            if seen.insert(canonical).inserted { homes.append(canonical) }
        }
        add(realUserHomePath())
        let usersDir = "/Users"
        if rootPaths.contains(where: { usersDir.isWithin($0) || $0.isWithin(usersDir) }),
           let entries = try? FileManager.default.contentsOfDirectory(atPath: usersDir) {
            for name in entries.sorted() where !name.hasPrefix(".") && name != "Shared" {
                let candidate = usersDir + "/" + name
                if let id = try? FileIdentity.read(URL(fileURLWithPath: candidate)), id.directory, !id.link {
                    add(candidate)
                }
            }
        }
        return homes
    }

    public static func realUserHomePath() -> String {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16384)
        let path = buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(getuid(), &record, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let directory = record.pw_dir else { return nil }
            return String(cString: directory)
        }
        return path ?? NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
    }
}
