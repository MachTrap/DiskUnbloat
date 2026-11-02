import Foundation

/// One explicit cache location and how its deletion candidates are derived from it.
public struct CleanupRoot: Sendable, Equatable {
    public enum Candidate: Sendable, Equatable {
        /// The cache location folder itself is the candidate.
        case rootItself
        /// Direct children of the location are candidates (default).
        case children
        /// Direct children are candidates, except the most recently used one.
        case childrenKeepingNewest
    }
    public let path: String
    public let candidate: Candidate
    /// A local remainder resolving against the real filesystem for roots whose leaf
    /// segment varies per user (message-app account directories): the first segment may
    /// carry one trailing `*` (for example `account-*/postbox/media`), and every existing
    /// directory that matches becomes its own `.rootItself` root. A fresh install or an
    /// unreadable container resolves to nothing instead of inventing paths — the grouped
    /// scan then simply lists no such location.
    public let wildcard: String?
    public init(path: String, candidate: Candidate = .children) {
        self.path = path; self.candidate = candidate; self.wildcard = nil
    }
    /// Declares a wildcard-expanded root; every resolved match is a `rootItself` cache.
    public init(path: String, wildcardPattern wildcard: String) {
        self.path = path; self.candidate = .rootItself; self.wildcard = wildcard
    }
    /// Wildcard entries become one static root per real match; everything else passes
    /// through unchanged.
    public func resolved() -> [CleanupRoot] {
        guard let wildcard, !wildcard.isEmpty else { return [self] }
        return Self.resolve(path: path, wildcard: wildcard)
    }
    /// Resolution reads the base directory directly: the wildcard's leading segment
    /// ("account-*") matches children by prefix, remaining segments are literal parts of
    /// the path, and only directories that exist on disk count. Non-matching children,
    /// plain files, and unrecognized layouts are skipped — never guessed.
    static func resolve(path: String, wildcard: String) -> [CleanupRoot] {
        var segments = wildcard.split(separator: "/").map(String.init)
        guard let pattern = segments.first, pattern.hasSuffix("*") else { return [] }
        let prefix = String(pattern.dropLast())
        let matches = (try? FileManager.default.contentsOfDirectory(atPath: path))?
            .filter { $0.hasPrefix(prefix) } ?? []
        guard !matches.isEmpty else { return [] }
        segments.removeFirst()
        var result: [CleanupRoot] = []
        for match in matches {
            var resolvedPath = path + "/" + match
            for segment in segments { resolvedPath += "/" + segment }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            result.append(CleanupRoot(path: resolvedPath, candidate: .rootItself))
        }
        return result
    }
}

/// Stable domain identifiers; presentation owns their localized names and explanations.
public enum CleanupRule: String, CaseIterable, Identifiable, Sendable {
    case large, downloads, archives, userCaches, derivedData, swiftPM, npm, pip, regenerable
    public var id: Self { self }
    public var isCache: Bool { [.userCaches, .derivedData, .swiftPM, .npm, .pip].contains(self) }
    public func root(relativeTo home: String) -> String? { roots(relativeTo: home).first?.path }
    /// Curated exact locations, home-relative. Multiple roots are combined with OR.
    /// Wildcard entries resolve against the real filesystem at call time, so a scanner
    /// or the cleanup plan always cites directories that exist right now.
    public func roots(relativeTo home: String) -> [CleanupRoot] {
        var result: [CleanupRoot] = []
        switch self {
        case .userCaches:
            result += [
                .init(path: home + "/Library/Caches"),
                .init(path: home + "/Library/Application Support/Unreal Tournament/Cache", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/Code - Insiders/WebStorage", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/Code - Insiders/agent-host/sdk-cache", candidate: .rootItself),
                .init(path: home + "/Library/Developer/Xcode/DerivedData"),
                .init(path: home + "/Library/Developer/Xcode/iOS DeviceSupport", candidate: .childrenKeepingNewest),
                .init(path: home + "/Library/Developer/Xcode/watchOS DeviceSupport", candidate: .childrenKeepingNewest),
                .init(path: home + "/Library/Developer/Xcode/tvOS DeviceSupport", candidate: .childrenKeepingNewest),
                .init(path: home + "/Library/Developer/Xcode/visionOS DeviceSupport", candidate: .childrenKeepingNewest),
                .init(path: home + "/Library/Developer/CoreSimulator/Devices", candidate: .childrenKeepingNewest),
                // Simulator-side throwaways: runtime system caches, SwiftUI preview devices,
                // and the clones parallel test runs leave behind. Xcode rebuilds all of them.
                .init(path: home + "/Library/Developer/CoreSimulator/Caches", candidate: .rootItself),
                .init(path: home + "/Library/Developer/Xcode/UserData/Previews/Simulator Devices"),
                .init(path: home + "/Library/Developer/XCTestDevices"),
                // Telegram Desktop's downloaded media per account: only the `postbox/media`
                // cache inside an `account-…` directory is a candidate, so the session and
                // the account data beside it survive every cleanup.
                .init(
                    path: home + "/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable",
                    wildcardPattern: "account-*/postbox/media"),
                .init(path: home + "/.cache/uv", candidate: .rootItself),
                .init(path: home + "/.gradle/caches", candidate: .rootItself),
                .init(path: home + "/.gradle/wrapper/dists", candidate: .childrenKeepingNewest),
                .init(path: home + "/.npm/_cacache"),
                // Rust: the registry's downloaded archives and unpacked sources plus the git
                // dependency caches. `.cargo/bin` is the user's installed executables and is
                // never listed; deleting these subfolders makes Cargo re-fetch on demand.
                .init(path: home + "/.cargo/registry/cache", candidate: .rootItself),
                .init(path: home + "/.cargo/registry/src", candidate: .rootItself),
                .init(path: home + "/.cargo/git/checkouts", candidate: .rootItself),
                .init(path: home + "/.cargo/git/db", candidate: .rootItself),
                // Bun's global package cache; `~/.bun/bin` holds user executables — untouched.
                .init(path: home + "/.bun/install/cache", candidate: .rootItself),
                // Automation browser builds: one version per browser family stays (Playwright
                // accumulates old `chromium-…` builds the same way old device support builds up).
                .init(path: home + "/Library/Caches/ms-playwright", candidate: .childrenKeepingNewest),
                .init(path: home + "/Library/Caches/Cypress", candidate: .childrenKeepingNewest),
            ]
            // Chromium caches and downloaded extension archives of VS Code, its Insiders
            // build, Cursor, and Windsurf; user settings and workspace storage under
            // `User/` stay protected by the managed-data guard.
            for editor in ["Code", "Code - Insiders", "Cursor", "Windsurf"] {
                let url = home + "/Library/Application Support/\(editor)"
                result += [
                    .init(path: url + "/Cache", candidate: .rootItself),
                    .init(path: url + "/CachedData", candidate: .rootItself),
                    .init(path: url + "/CachedExtensionVSIXs", candidate: .rootItself),
                    .init(path: url + "/GPUCache", candidate: .rootItself),
                    // The remaining Chromium storage: compiled-code cache and the
                    // service-worker HTTP cache.
                    .init(path: url + "/Code Cache", candidate: .rootItself),
                    .init(path: url + "/Service Worker/CacheStorage", candidate: .rootItself),
                ]
            }
            // ComfyUI Desktop's Electron caches — the current app's Chromium caches and
            // the legacy 1.x desktop's. The installs (~/ComfyUI-Installs), the shared
            // model library, and the user workfiles beside them are never listed.
            result += [
                .init(path: home + "/Library/Application Support/Comfy Desktop/Cache", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/Comfy Desktop/Code Cache", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/Comfy Desktop/GPUCache", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/ComfyUI/Cache", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/ComfyUI/Code Cache", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/ComfyUI/GPUCache", candidate: .rootItself),
                // Unity's Package Manager global cache. No verified editor bundle ID
                // exists, so there is no running-app guard — the cache regenerates even
                // beside a running editor.
                .init(path: home + "/Library/Unity/cache", candidate: .rootItself),
                // DaVinci Resolve's Fusion node disk cache (P5 keeps the project database
                // and galleries protected under managed-data rules; no verified bundle ID
                // exists for a running-app guard).
                .init(path: home + "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/DiskCache", candidate: .rootItself),
                // Figma's Chromium caches beside the desktop profile.
                .init(path: home + "/Library/Application Support/Figma/DesktopProfile/Cache", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/Figma/DesktopProfile/Code Cache", candidate: .rootItself),
                .init(path: home + "/Library/Application Support/Figma/DesktopProfile/GPUCache", candidate: .rootItself),
                // Adobe's shared video cache lives in Application Support, so these exact
                // folders must be listed for the media cache to be cleanable at all. Premiere,
                // After Effects, Media Encoder, and Audition re-conform everything they need,
                // and the app-activity guard blocks removal while any of them runs.
                .init(path: home + "/Library/Application Support/Adobe/Common/Media Cache Files"),
                .init(path: home + "/Library/Application Support/Adobe/Common/Media Cache"),
                .init(path: home + "/Library/Application Support/Adobe/Common/Peak Files"),
                .init(path: home + "/Library/Application Support/Adobe/Common/PTX"),
                // Unreal Engine 5.4+'s shared Zen store: the local Derived Data Cache plus
                // cooked output, all derived from project assets and DDC data. Rebuilding
                // costs time, never data — like Xcode's Derived Data above.
                .init(path: home + "/Library/Application Support/Epic/UnrealEngine/Common/Zen/Data"),
                // nektos/act's downloaded GitHub Actions and workflow cache artifacts; the
                // runner re-fetches everything per run.
                .init(path: home + "/.cache/act", candidate: .rootItself),
                // Godot's export templates: one installation per engine version beside the
                // editor data. `app_userdata` holds `user://` game saves and is never listed.
                .init(path: home + "/Library/Application Support/Godot/export_templates", candidate: .childrenKeepingNewest),
                // Terraform provider binaries, sccache's object store, PHP Composer's archives,
                // Ivy's dependency cache, and Deno's custom-layout cache; each tool re-fetches
                // its own contents on demand. Terraform's `rc.json`/checkpoint and Composer's
                // `auth.json`/`config.json` beside them are never listed.
                .init(path: home + "/.terraform.d/plugin-cache", candidate: .rootItself),
                .init(path: home + "/.cache/sccache", candidate: .rootItself),
                .init(path: home + "/.composer/cache", candidate: .rootItself),
                .init(path: home + "/.ivy2/cache", candidate: .rootItself),
                .init(path: home + "/.deno/cache", candidate: .rootItself),
            ]
        case .derivedData: result = [.init(path: home + "/Library/Developer/Xcode/DerivedData")]
        case .swiftPM: result = [.init(path: home + "/Library/Caches/org.swift.swiftpm")]
        case .npm: result = [.init(path: home + "/.npm/_cacache")]
        case .pip: result = [.init(path: home + "/Library/Caches/pip")]
        case .downloads: result = [.init(path: home + "/Downloads")]
        default: break
        }
        return result.flatMap { $0.resolved() }
    }
    /// Directory names whose contents tools can usually rebuild or download again. The
    /// list is deliberately unambiguous — exclusively generated by compilers, bundlers,
    /// linters, or runners, never holding hand-written sources — and stays tier-2-only.
    /// Context-dependent names join `regenerableManifests` instead, where a sibling
    /// project marker verifies the tool context.
    public static let regenerableNames: [String] = [
        "node_modules", "Pods", "DerivedData", ".cache", ".artifacts", ".build", ".build-cache",
        // Front-end framework build and cache folders.
        ".next", ".nuxt", ".svelte-kit", ".astro", ".angular", ".docusaurus", ".turbo", ".parcel-cache", ".vite",
        // Godot 4's project-local import and build cache (Unity's Library equivalent,
        // renamed in engine 4; distinctive enough to need no sibling evidence).
        ".godot",
        // Python tooling caches and ephemeral test virtual environments.
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox", ".dart_tool",
        // Build-system and bundler work folders with distinctive names.
        ".gradle", ".zig-cache", "zig-cache", "zig-out", "cmake-build-debug", "cmake-build-release",
        ".serverless", ".terragrunt-cache",
        // DaVinci Resolve's per-render-cache folder (`.dvcc` files) beside the media
        // storage; the project database and galleries stay protected, and deletion only
        // costs re-rendering on the next playback.
        "CacheClip",
    ]
    /// Context-verified regenerable folders: the name alone is not distinctive, so a
    /// sibling project marker stored in the parent must prove the tool context. A folder
    /// matches when its name equals `name` and its parent holds evidence — at least one
    /// marker from `anySiblings`, at least one marker ending with `anySiblingSuffixes`, or
    /// every marker of `allSiblings` when the others are empty. The list stays closed:
    /// only names whose genericity is bound by a project file join here, and unknown
    /// future names stay out until added deliberately.
    public struct RegenerableManifest: Sendable, Equatable {
        public let name: String
        public let anySiblings: [String]
        public let allSiblings: [String]
        public let anySiblingSuffixes: [String]
        public init(name: String, anySiblings: [String] = [], allSiblings: [String] = [], anySiblingSuffixes: [String] = []) {
            self.name = name; self.anySiblings = anySiblings; self.allSiblings = allSiblings
            self.anySiblingSuffixes = anySiblingSuffixes
        }
    }
    public static let regenerableManifests: [RegenerableManifest] = [
        // Rust's and Maven's `target` folders sit beside the project manifest that
        // directs every rebuild into them.
        .init(name: "target", anySiblings: ["Cargo.toml", "pom.xml"]),
        // Python virtual environments only count beside the files that created them
        // (both the dot-prefixed and the plainly named folder are never hand-written).
        .init(name: ".venv", anySiblings: ["pyproject.toml", "requirements.txt", "Pipfile", "uv.lock", "poetry.lock"]),
        .init(name: "venv", anySiblings: ["pyproject.toml", "requirements.txt", "Pipfile", "uv.lock", "poetry.lock"]),
        // Unity's project-local Library only counts beside the two Unity project
        // siblings, so `~/Library` and ordinary data folders can never be shadowed.
        .init(name: "Library", allSiblings: ["Assets", "ProjectSettings"]),
        // Unreal Engine projects: C++ intermediates and the per-project Derived Data
        // Cache sit beside the `.uproject` (or plugin `.uplugin`) descriptor that builds
        // them. The 5.4+ shared Zen store is a curated cache root above; `Saved` holds
        // settings, crash data, and autosaves (user-authored), so it never matches.
        .init(name: "Intermediate", anySiblingSuffixes: [".uproject", ".uplugin"]),
        .init(name: "DerivedDataCache", anySiblingSuffixes: [".uproject", ".uplugin"]),
    ]
    /// Prefixes matching regenerable directories such as `.derivedData-mapcheck`.
    public static let regenerableNamePrefixes: [String] = [".derivedData"]
    public static func isRegenerableName(_ name: String) -> Bool {
        regenerableNames.contains(name) || regenerableNamePrefixes.contains { name.hasPrefix($0) }
    }
}
