import Foundation

/// The nested quick-select levels of the cleanup queue. Each level selects everything the
/// previous one does, plus more: `junk ⊆ caches ⊆ rebuildable ⊆ deep` for every rule.
public enum AutoSelectionLevel: Int, Sendable, CaseIterable, Identifiable, Comparable {
    /// Junk that is safe to delete: curated caches, previous versions, long-unused models.
    case junk = 1
    /// Plus every live application cache (`~/Library/Caches`) and package-manager stores.
    case caches
    /// Plus content that can be rebuilt or downloaded again: current simulators and
    /// device data, model stores, `node_modules`-style project folders.
    case rebuildable
    /// Plus leftovers that may still matter to someone: settings of older app versions
    /// and long-unused installer files.
    case deep
    public var id: Int { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What a level takes from one curated location's candidates.
public enum SelectionCoverage: Sendable, Equatable {
    /// Nothing.
    case none
    /// Every candidate (build data and known regenerable caches).
    case all
    /// Every child except the `keep` most recent ones — "previous versions". When the
    /// location has no previous versions (at most `keep` children), the long-unused ones
    /// qualify instead — but the single most recent version is always preserved.
    case previousVersions(keep: Int)
    /// Every entry except the `keep` most recent ones of each versioned family (see
    /// `AutoSelection.versionedFamilyKey`). A family without previous versions never loses
    /// its sole entry, though its long-unused older entries can qualify like
    /// `previousVersions`.
    case previousVersionsPerFamily(keep: Int)
    /// Every application-version folder except the `keep` most recent ones of each app
    /// (see `AutoSelection.appVersionFamilyKey`). Sole versions and non-versioned
    /// children always stay; there is no long-unused fallback.
    case previousAppVersions(keep: Int)
    /// Long-unused children, never the single most recent one (Android virtual devices).
    case unusedKeepingNewest
    /// Long-unused eligible children only (model stores, old installers).
    case unusedOnly
}

/// Directory/sidecar pairing for locations where one simulator is two entries:
/// a `<base><directorySuffix>` folder plus its `<base><sidecarSuffix>` file.
public struct SidecarPairing: Sendable, Equatable {
    public let directorySuffix: String
    public let sidecarSuffix: String
    public init(directorySuffix: String, sidecarSuffix: String) {
        self.directorySuffix = directorySuffix
        self.sidecarSuffix = sidecarSuffix
    }
}

/// One curated location and how the levels cover it. The auto-selection list is closed:
/// nothing outside these rules is ever selected automatically.
///
/// Levels below `fullFrom` take the `junk` coverage; `fullFrom` and every higher level
/// take the `full` coverage. Nesting holds by construction because `junk` is either
/// `.none`, the same as `full`, or `full` is `.all` (enforced in `init`).
public struct AutoSelectionRule: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// The location folder itself is the candidate (small curated caches).
        case locationItself
        /// The location's direct children are candidates; the folder stays.
        case children
    }
    /// Home-relative path of the curated location; `nil` marks the name-matched
    /// regenerable folders (node_modules, Pods, .build, …) found anywhere in the scan.
    public let relativePath: String?
    public let target: Target
    /// What the junk level (and any level below `fullFrom`) takes.
    public let junk: SelectionCoverage
    /// The first level that takes the `full` coverage.
    public let fullFrom: AutoSelectionLevel
    /// What `fullFrom` and every higher level take; `.all` unless a location must stay
    /// selective even at its top level (old installers, older app versions).
    public let full: SelectionCoverage
    public let sidecarPairing: SidecarPairing?
    /// Only these direct children are ever candidates at any level; `nil` means every
    /// child. A closed list: user-authored content stored beside the caches (LM Studio
    /// chats, conversations, presets) never qualifies, and unknown future children stay
    /// out until added here deliberately.
    public let eligibleChildNames: Set<String>?
    /// Only files with these lowercased extensions are candidates (directories never);
    /// `nil` means no extension filter.
    public let eligibleExtensions: Set<String>?
    /// The exact items this rule selects are exempt from managed-data protection for the
    /// recommendation that selected them (older app versions' folders under Application
    /// Support). The location itself and its unselected children stay protected.
    public let exemptsSelection: Bool
    public init(
        relativePath: String?, target: Target, junk: SelectionCoverage, fullFrom: AutoSelectionLevel,
        full: SelectionCoverage = .all, sidecarPairing: SidecarPairing? = nil,
        eligibleChildNames: Set<String>? = nil, eligibleExtensions: Set<String>? = nil, exemptsSelection: Bool = false
    ) {
        precondition(junk == .none || junk == full || full == .all, "junk coverage must nest inside full coverage")
        precondition(target == .children || (full == .all && (junk == .all || junk == .none)), "a location itself is taken whole or not at all")
        self.relativePath = relativePath
        self.target = target
        self.junk = junk
        self.fullFrom = fullFrom
        self.full = full
        self.sidecarPairing = sidecarPairing
        self.eligibleChildNames = eligibleChildNames
        self.eligibleExtensions = eligibleExtensions
        self.exemptsSelection = exemptsSelection
    }
    /// The coverage one level applies to this location.
    public func coverage(at level: AutoSelectionLevel) -> SelectionCoverage { level >= fullFrom ? full : junk }
}

/// The closed automatic-selection spec, home-relative. Cache-side entries derive from
/// `CleanupRule.userCaches` so quick scans, cleanup candidates, and auto-selection can
/// never drift apart; the developer-side locations are explicit.
public enum AutoSelectionSpec {
    public static func rules(home: String) -> [AutoSelectionRule] {
        var rules: [AutoSelectionRule] = []
        for root in CleanupRule.userCaches.roots(relativeTo: home) {
            guard root.path.hasPrefix(home + "/") else { continue }
            let relative = String(root.path.dropFirst(home.count + 1))
            switch root.candidate {
            case .rootItself:
                rules.append(AutoSelectionRule(relativePath: relative, target: .locationItself, junk: .all, fullFrom: .junk))
            case .children:
                // The live ~/Library/Caches tree joins at the caches level; every other
                // curated cache location is junk that is safe to delete.
                if root.path == home + "/Library/Caches" {
                    rules.append(AutoSelectionRule(relativePath: relative, target: .children, junk: .none, fullFrom: .caches))
                } else {
                    rules.append(AutoSelectionRule(relativePath: relative, target: .children, junk: .all, fullFrom: .junk))
                }
            case .childrenKeepingNewest:
                // Older device-support versions (keep the newest), older simulator devices
                // (keep the two newest), and old automation-browser builds (keep one
                // version of every browser family) are junk; the current ones are
                // rebuildable.
                let keep = root.path.hasSuffix("CoreSimulator/Devices") ? 2 : 1
                rules.append(AutoSelectionRule(
                    relativePath: relative, target: .children,
                    junk: root.path.hasSuffix("ms-playwright")
                        ? .previousVersionsPerFamily(keep: keep)
                        : .previousVersions(keep: keep),
                    fullFrom: .rebuildable))
            }
        }
        rules += [
            AutoSelectionRule(relativePath: "Library/Android/sdk/system-images", target: .children, junk: .previousVersions(keep: 1), fullFrom: .rebuildable),
            AutoSelectionRule(relativePath: "Library/Android/sdk/ndk", target: .children, junk: .previousVersions(keep: 1), fullFrom: .rebuildable),
            AutoSelectionRule(
                relativePath: ".android/avd", target: .children, junk: .unusedKeepingNewest, fullFrom: .rebuildable,
                sidecarPairing: SidecarPairing(directorySuffix: ".avd", sidecarSuffix: ".ini")),
            AutoSelectionRule(
                relativePath: ".cache/lm-studio", target: .children, junk: .unusedOnly, fullFrom: .rebuildable,
                // The store holds user-authored content beside regenerable ones: chat
                // history and presets can never be regenerated or restored, so only the
                // known regenerable children ever qualify.
                eligibleChildNames: ["models", "extensions", ".internal", ".session_cache"]),
            // The same story for LM Studio's newer store layout: models, the hub, and
            // the internal cache are regenerable; conversations and presets never are.
            AutoSelectionRule(
                relativePath: ".lmstudio", target: .children, junk: .unusedOnly, fullFrom: .rebuildable,
                eligibleChildNames: ["models", "hub", ".internal"]),
            // Local model and dataset stores: long-unused weights are junk, everything
            // eligible is rebuildable. Auth tokens are never in the closed lists.
            AutoSelectionRule(
                relativePath: ".cache/huggingface", target: .children, junk: .unusedOnly, fullFrom: .rebuildable,
                eligibleChildNames: ["hub", "datasets"]),
            AutoSelectionRule(relativePath: ".cache/huggingface/xet", target: .children, junk: .all, fullFrom: .junk),
            AutoSelectionRule(
                relativePath: ".cache/torch", target: .children, junk: .unusedOnly, fullFrom: .rebuildable,
                eligibleChildNames: ["hub", "inductor"]),
            AutoSelectionRule(relativePath: ".cache/mlx", target: .children, junk: .unusedOnly, fullFrom: .rebuildable),
            AutoSelectionRule(relativePath: ".cache/whisper", target: .children, junk: .unusedOnly, fullFrom: .rebuildable),
            // Compiled GPU kernels: pure cache, every child qualifies immediately.
            AutoSelectionRule(relativePath: ".triton/cache", target: .children, junk: .all, fullFrom: .junk),
            // Go: junk clears the download cache; the caches level additionally takes every
            // extracted module tree (read-only files travel to Trash from the writable
            // parent, and the queue's topmost-only normalization folds the nested cache).
            AutoSelectionRule(relativePath: "go/pkg/mod", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: "go/pkg/mod/cache", target: .locationItself, junk: .all, fullFrom: .junk),
            // Polyglot package stores: package-manager caches, taken in full from the
            // caches level.
            AutoSelectionRule(relativePath: "Library/pnpm/store", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: ".local/share/pnpm/store", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: ".pnpm-store", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: ".nuget/packages", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: ".pub-cache", target: .children, junk: .none, fullFrom: .caches),
            // Minikube's pure download caches (ISO images, container base images); the
            // cluster VM disk under `~/.minikube` itself is never auto-selected.
            AutoSelectionRule(relativePath: ".minikube/cache", target: .children, junk: .none, fullFrom: .caches),
            // The default self-hosted GitHub Actions runner layout: the tool cache's SDK
            // stacks and cached action checkouts are re-downloaded per run. The runner
            // binaries and configuration above this path are never listed.
            AutoSelectionRule(relativePath: "actions-runner/_work/_tool", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: "actions-runner/_work/_actions", target: .children, junk: .none, fullFrom: .caches),
            // Ollama's model store: only the `models` tree is a candidate, and only whole —
            // multiple models share layer blobs, so partial selection would be unsafe, and
            // the `id_ed25519` keypair and every other child stay out.
            AutoSelectionRule(
                relativePath: ".ollama", target: .children, junk: .none, fullFrom: .rebuildable,
                eligibleChildNames: ["models"]),
            // Unity's downloaded Asset Store package archives: re-downloadable. (The UPM
            // global cache is a curated junk cache root instead.)
            AutoSelectionRule(relativePath: "Library/Unity/Asset Store-5.x", target: .children, junk: .none, fullFrom: .rebuildable),
            // Conda's package caches: hard-linked into live environments, so only from the
            // caches level in full; the package manager prefers `conda clean --all` and
            // re-pulls anything missing.
            AutoSelectionRule(relativePath: ".conda/pkgs", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: "anaconda3/pkgs", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: "miniconda3/pkgs", target: .children, junk: .none, fullFrom: .caches),
            AutoSelectionRule(relativePath: "miniforge3/pkgs", target: .children, junk: .none, fullFrom: .caches),
            // CLIP and Keras model stores: long-unused checkpoint families are junk.
            AutoSelectionRule(relativePath: ".cache/clip", target: .children, junk: .unusedOnly, fullFrom: .rebuildable),
            AutoSelectionRule(
                relativePath: ".keras", target: .children, junk: .unusedOnly, fullFrom: .rebuildable,
                eligibleChildNames: ["models", "datasets"]),
            // Name-matched rebuildable folders anywhere in the scan.
            AutoSelectionRule(relativePath: nil, target: .children, junk: .none, fullFrom: .rebuildable),
        ]
        rules += deepRules
        return rules
    }

    /// Deep-clean-only locations: never below the deep level, and selective even there.
    static let deepRules: [AutoSelectionRule] = [
        // Installer images and packages left in Downloads once they have not been touched
        // for the long-unused threshold. Nothing else in Downloads ever qualifies: age
        // alone never makes a file safe to delete.
        AutoSelectionRule(
            relativePath: "Downloads", target: .children, junk: .none, fullFrom: .deep, full: .unusedOnly,
            eligibleExtensions: installerExtensions),
    ] + AppVersionSettings.locations.map {
        // Older versions' settings and support folders; the most recently used version
        // of every family stays, and non-versioned children are families of their own.
        AutoSelectionRule(
            relativePath: $0, target: .children, junk: .none, fullFrom: .deep,
            full: .previousAppVersions(keep: 1), exemptsSelection: true)
    }

    /// Disk images and installer packages (`.dmg`, `.pkg`, `.mpkg`, `.xip`).
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
}

/// Pure level decisions over one location's candidate children. Recency is the subtree's
/// latest recorded content modification (the index's honest "most recently used" signal),
/// with the name as the deterministic tie-break — never access dates.
public enum AutoSelection {
    /// Whether a candidate counts as long-unused: its subtree has no recorded content
    /// modification inside the threshold and its dates and sizes are known. Unknown data
    /// never establishes eligibility.
    public static func isLongUnused(_ node: FileNode, before cutoff: Date) -> Bool {
        node.unknownModificationCount == 0
            && node.unknownAllocatedCount == 0
            && (node.latestContentModification ?? .distantPast) < cutoff
    }

    /// The family of a versioned build entry: `chromium-1148` belongs to `chromium`,
    /// while names without a trailing dash and digits are families of their own. Kept
    /// deliberately narrow for automation-browser builds, where lookalike names must not
    /// be grouped.
    public static func versionedFamilyKey(_ name: String) -> String {
        guard let index = name.lastIndex(where: { !$0.isNumber }),
              name[index...].hasPrefix("-") else { return name }
        return String(name[..<index])
    }

    /// The family of an application-version folder, so older versions are judged per app:
    /// - `AutoCAD 2023`, `Live 11.3.4`, `Cinema 4D 2024_8A6D4B5E`, `chromium-1148` → the
    ///   name before the version (a separator, an optional `v`, dotted digits, an optional
    ///   `_id` suffix);
    /// - `4.2`, `2025` → one shared family of bare versions (Blender, Maya year folders).
    /// Names without a version token are families of their own, so they are never treated
    /// as an older version of anything.
    public static func appVersionFamilyKey(_ name: String) -> String {
        if name.wholeMatch(of: /v?\d+(\.\d+)*/) != nil { return "#version" }
        if let match = name.wholeMatch(of: /(.+?)[ _\-]v?\d+(?:\.\d+)*(?:_[0-9A-Za-z]+)?/) {
            let family = String(match.1).trimmingCharacters(in: .whitespaces)
            if !family.isEmpty { return family }
        }
        return name
    }

    /// One level's selection over one location's direct children. Symlinks and package
    /// internals never qualify; paired sidecars travel with their directory; children
    /// outside the rule's closed name or extension lists are never selected at any level.
    public static func select(
        children: [FileNode], rule: AutoSelectionRule, level: AutoSelectionLevel, unusedBefore cutoff: Date
    ) -> [FileNode] {
        var eligible = children
        if let names = rule.eligibleChildNames {
            eligible = eligible.filter { names.contains($0.name) }
        }
        if let extensions = rule.eligibleExtensions {
            eligible = eligible.filter { !$0.isDirectory && extensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        }
        let primaries: [FileNode]
        var sidecarByName: [String: FileNode] = [:]
        if let pairing = rule.sidecarPairing {
            primaries = eligible.filter { $0.isDirectory && !$0.isSymbolicLink && !$0.packageAncestor && $0.name.hasSuffix(pairing.directorySuffix) }
            for child in eligible where !child.isDirectory {
                sidecarByName[child.name] = child
            }
        } else {
            primaries = eligible.filter { !$0.isSymbolicLink && !$0.packageAncestor }
        }
        let ranked = primaries.sorted { a, b in
            let left = a.latestContentModification ?? .distantPast
            let right = b.latestContentModification ?? .distantPast
            return left == right ? a.name > b.name : left > right
        }
        let selected: [FileNode]
        switch rule.coverage(at: level) {
        case .none:
            selected = []
        case .all:
            selected = ranked
        case .previousVersions(let keep):
            // Previous versions first; when the location has none, the long-unused
            // ones qualify instead of being kept as "the most recent" — but the
            // single most recent version is preserved either way.
            let previous = Array(ranked.dropFirst(keep))
            selected = previous.isEmpty
                ? Array(ranked.dropFirst(1)).filter { isLongUnused($0, before: cutoff) }
                : previous
        case .previousVersionsPerFamily(let keep):
            // Per family the newest `keep` entries stay; sole entries are always
            // preserved, and a family's long-unused entries qualify the same way.
            var familyIDs = Set<Int64>()
            for versions in Dictionary(grouping: ranked, by: { versionedFamilyKey($0.name) }).values {
                let previous = Array(versions.dropFirst(keep))
                if previous.isEmpty {
                    familyIDs.formUnion(versions.dropFirst(1).filter { isLongUnused($0, before: cutoff) }.map(\.id))
                } else {
                    familyIDs.formUnion(previous.map(\.id))
                }
            }
            selected = ranked.filter { familyIDs.contains($0.id) }
        case .previousAppVersions(let keep):
            var familyIDs = Set<Int64>()
            for versions in Dictionary(grouping: ranked, by: { appVersionFamilyKey($0.name) }).values {
                // A non-versioned name is its own family of one and therefore always stays.
                familyIDs.formUnion(versions.dropFirst(max(1, keep)).map(\.id))
            }
            selected = ranked.filter { familyIDs.contains($0.id) }
        case .unusedKeepingNewest:
            selected = ranked.dropFirst(1).filter { isLongUnused($0, before: cutoff) }
        case .unusedOnly:
            selected = ranked.filter { isLongUnused($0, before: cutoff) }
        }
        guard let pairing = rule.sidecarPairing else { return selected }
        // Each selected simulator brings its configuration sidecar along.
        return selected + selected.compactMap { node in
            let base = String(node.name.dropLast(pairing.directorySuffix.count))
            return sidecarByName[base + pairing.sidecarSuffix]
        }
    }
}

/// One curated location's contribution to an automatic selection.
public struct AutoSelectionGroup: Sendable {
    /// The curated location itself (or the name-matched folder).
    public let location: FileNode
    /// The nodes to queue: the location's selected children, or the location itself.
    public let nodes: [FileNode]
    /// True when `nodes` are the location's children and cover every indexed child, so a
    /// scan root can be queued as one "clean contents, keep folder" entry instead.
    public let coversAllChildren: Bool
    /// The nodes' exact paths are exempt from managed-data protection for this
    /// recommendation (see `AutoSelectionRule.exemptsSelection`).
    public let exemptsSelection: Bool
    public init(location: FileNode, nodes: [FileNode], coversAllChildren: Bool, exemptsSelection: Bool = false) {
        self.location = location
        self.nodes = nodes
        self.coversAllChildren = coversAllChildren
        self.exemptsSelection = exemptsSelection
    }
}

/// Everything one level selects over the current index, grouped per curated location.
public struct AutoSelectionResult: Sendable {
    public let groups: [AutoSelectionGroup]
    public init(groups: [AutoSelectionGroup]) { self.groups = groups }
    public var nodes: [FileNode] { groups.flatMap(\.nodes) }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.nodes.count } }
    public var knownBytes: Int64 { nodes.reduce(0) { $0 + $1.knownSize(for: .allocated) } }
    public var unknownCount: Int { nodes.reduce(0) { $0 + ($1.unknownAllocatedCount > 0 ? 1 : 0) } }
    public var isEmpty: Bool { groups.allSatisfy { $0.nodes.isEmpty } }
    /// Exact paths a recommendation may remove despite managed-data protection.
    public var exemptPaths: Set<String> { Set(groups.filter(\.exemptsSelection).flatMap { $0.nodes.map(\.path) }) }
}

/// The honest estimate shown for a level before anything is selected: entries and bytes
/// after the queue's topmost-only normalization, so a folder and its selected children
/// are never counted twice.
public struct AutoSelectionPreview: Sendable, Equatable {
    public let items: Int
    public let knownBytes: Int64
    public init(items: Int, knownBytes: Int64) {
        self.items = items
        self.knownBytes = knownBytes
    }
    public init(_ result: AutoSelectionResult) {
        var byPath: [String: FileNode] = [:]
        for node in result.nodes { byPath[node.path] = node }
        let kept = HiddenRanges.pruneSubsumed(Array(byPath.keys))
        items = kept.count
        knownBytes = kept.reduce(0) { $0 + (byPath[$1]?.knownSize(for: .allocated) ?? 0) }
    }
}
