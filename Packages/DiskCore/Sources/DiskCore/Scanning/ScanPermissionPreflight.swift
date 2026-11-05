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
        // Third-party application data (Firefox profiles, Discord stores, Chrome caches,
        // editors' settings — everything beside the com.apple.* entries) is gated by the
        // macOS 26 App Data consent ("would like to access data from other apps"). Probing
        // the directory itself never triggers that prompt — only opening child
        // applications' data does — so the directory is probed with children depth right
        // after Apple's protected folders.
        ("Library/Application Support", .childrenAndBundles),
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

    /// The single consent the minimal policy asks for: other applications' data. Probing
    /// app containers (and Application Support children) raises that one dialog; once it
    /// is answered, later probes of the same service do not prompt again.
    public static let minimalConsentTargets: [(path: String, depth: ProbeDepth)] = [
        ("Library/Containers", .childrenAndBundles),
        ("Library/Application Support", .childrenAndBundles),
    ]

    /// Personal-data stores each guarded by their own consent service. Under the minimal
    /// policy they are never opened — their size stays honestly unknown and the scan
    /// explains Full Disk Access once — so no further dialog can appear mid-scan.
    public static let minimalSkippedRelativePaths: [String] = [
        "Pictures/Photos Library.photoslibrary",
        "Music/Music",
        "Music/iTunes",
        "Movies/TV",
        "Library/Photos",
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
        "Library/HomeKit",
        "Library/Calendars",
        "Library/Reminders",
        "Library/Mobile Documents",
        "Library/Application Support/AddressBook",
        "Library/Application Support/com.apple.avfoundation",
        "Library/Group Containers/group.com.apple.photolibraryd",
        "Library/Group Containers/group.com.apple.calendar",
        "Library/Group Containers/group.com.apple.reminders",
        "Library/Group Containers/group.com.apple.notes",
        "Library/Group Containers/group.com.apple.music",
    ]

    /// In-scope personal-data stores the minimal policy skips (empty for full access).
    public static func skippedPaths(for request: ScanRequest, homes: [URL]? = nil) -> [String] {
        guard request.options.consentPolicy == .minimal else { return [] }
        return scoped(request, homes: homes, relative: minimalSkippedRelativePaths.map { ($0, .directoryOnly) }, includeVolumes: false).map(\.url.path)
    }

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
        switch request.options.consentPolicy {
        case .fullDiskAccess: scoped(request, homes: homes, relative: homeRelativeTargets, includeVolumes: true)
        case .minimal: scoped(request, homes: homes, relative: minimalConsentTargets, includeVolumes: false)
        }
    }

    private static func scoped(_ request: ScanRequest, homes: [URL]?, relative: [(path: String, depth: ProbeDepth)], includeVolumes: Bool) -> [Target] {
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

        let explicit = homes ?? request.options.homePaths.map { $0.map { URL(fileURLWithPath: $0) } }
        let candidateHomes = resolvedHomes(explicit: explicit, rootPaths: rootEntries.map(\.path))
        var seen = Set<String>()
        var result: [Target] = []

        func appendTarget(_ path: String, depth: ProbeDepth) {
            guard seen.insert(path).inserted, isIncluded(path) else { return }
            result.append(Target(url: URL(fileURLWithPath: path, isDirectory: true), depth: depth))
        }

        for home in candidateHomes where rootEntries.contains(where: { $0.path.overlaps(home) }) {
            for entry in relative {
                appendTarget(home + "/" + entry.path, depth: entry.depth)
            }
        }
        guard includeVolumes else { return result }

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

    /// How a preflight open of one protected target went. The denial outcome exists to tell
    /// the user *why* some folders stay unsized: macOS refuses those reads at a level where
    /// no consent dialog exists, and Full Disk Access is the supported way out.
    public enum ProbeOutcome: Sendable, Equatable {
        case readable
        /// One or more of the touched directories refused opening with a permission error,
        /// while others in the same target opened — the signature of macOS-protected
        /// content (media libraries, other applications' app data, mail and messages).
        case containsDeniedChildren
    }

    /// Touches `target` with bounded `opendir`/`readdir` calls so macOS TCC presents any needed
    /// consent dialog immediately without enumerating the full subtree.
    @discardableResult
    public static func probe(_ target: Target, excludedPaths: [String] = []) -> ProbeOutcome {
        let path = target.url.path
        guard !excludedPaths.contains(where: { path.isWithin($0) }) else { return .readable }
        guard let dir = opendir(path) else { return .containsDeniedChildren }
        defer { closedir(dir) }

        switch target.depth {
        case .directoryOnly:
            _ = readdir(dir)
            return .readable
        case .childrenAndBundles:
            var denied = false
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
                } else if childDirectories.count < 4 {
                    // Four immediate child directories: Application Support mixes dozens of
                    // com.apple.* and third-party folders in readdir order, and the App Data
                    // consent fires only at the first touch of another application's data,
                    // so a couple of children are not enough to guarantee it.
                    childDirectories.append(childPath)
                }
            }
            for bundlePath in mediaBundles {
                if !probeMediaBundle(at: bundlePath, excludedPaths: excludedPaths) { denied = true }
            }
            if Self.isMediaBundlePath(path) {
                denied = denied || deniedChild(among: childDirectories, excludedPaths: excludedPaths)
            } else {
                denied = denied || deniedChild(among: childDirectories, excludedPaths: excludedPaths, openDataContainers: true)
            }
            return denied ? .containsDeniedChildren : .readable
        }
    }

    private static func deniedChild(among paths: [String], excludedPaths: [String], openDataContainers: Bool = false) -> Bool {
        var denied = false
        for childPath in paths {
            if shallowOpen(childPath) == nil {
                denied = true
                continue
            }
            guard openDataContainers else { continue }
            let dataPath = childPath + "/Data"
            if !excludedPaths.contains(where: { dataPath.isWithin($0) }),
               let id = try? FileIdentity.read(URL(fileURLWithPath: dataPath)),
               id.directory, !id.link,
               shallowOpen(dataPath) == nil {
                denied = true
            }
        }
        return denied
    }

    private static func isMediaBundlePath(_ path: String) -> Bool {
        let lower = (path as NSString).lastPathComponent.lowercased()
        return mediaBundleSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Opens the bundle's immediate children; returns whether every opened call succeeded.
    private static func probeMediaBundle(at bundlePath: String, excludedPaths: [String]) -> Bool {
        guard let dir = opendir(bundlePath) else { return false }
        defer { closedir(dir) }
        var denied = false
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
            if let id = try? FileIdentity.read(URL(fileURLWithPath: subPath)), id.directory, !id.link,
               shallowOpen(subPath) == nil {
                denied = true
            }
        }
        return !denied
    }

    /// Opens one directory for a bounded read; the return value exposes whether macOS refused it.
    private static func shallowOpen(_ path: String) -> CInt? {
        guard let dir = opendir(path) else { return nil }
        _ = readdir(dir)
        closedir(dir)
        return 1
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
