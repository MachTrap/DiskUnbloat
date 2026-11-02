import Foundation

/// The two automatic-selection tiers offered by the cleanup queue's quick-select buttons.
public enum AutoSelectionTier: String, Sendable, CaseIterable, Identifiable {
    /// Category 1: junk and caches that are safe to delete.
    case safe
    /// Category 2: content that might be useful but can be regenerated or restored.
    case regenerable
    public var id: String { rawValue }
}

/// What tier 1 selects from one curated location. Tier 2 always covers the whole location.
public enum Tier1Coverage: Sendable, Equatable {
    /// Never selected in tier 1 (the live `~/Library/Caches` tree).
    case none
    /// Selected in full (build data and known regenerable caches).
    case all
    /// Every child except the `keep` most recent ones — "previous versions". When the
    /// location has no previous versions (at most `keep` children), the long-unused ones
    /// qualify instead.
    case previousVersions(keep: Int)
    /// Long-unused children, never the single most recent one (Android virtual devices).
    case unusedKeepingNewest
    /// Long-unused children only (LM Studio models).
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

/// One curated location and how the two tiers cover it. The auto-selection list is closed:
/// nothing outside these rules is ever selected automatically.
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
    public let coverage: Tier1Coverage
    public let sidecarPairing: SidecarPairing?
    public init(relativePath: String?, target: Target, coverage: Tier1Coverage, sidecarPairing: SidecarPairing? = nil) {
        self.relativePath = relativePath
        self.target = target
        self.coverage = coverage
        self.sidecarPairing = sidecarPairing
    }
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
                rules.append(AutoSelectionRule(relativePath: relative, target: .locationItself, coverage: .all))
            case .children:
                // The live ~/Library/Caches tree is the one curated location tier 1 skips;
                // every other curated cache location is junk that is safe to delete.
                let coverage: Tier1Coverage = root.path == home + "/Library/Caches" ? .none : .all
                rules.append(AutoSelectionRule(relativePath: relative, target: .children, coverage: coverage))
            case .childrenKeepingNewest:
                // Older device-support versions (keep the newest) and older simulators
                // (keep the two newest).
                let keep = root.path.hasSuffix("CoreSimulator/Devices") ? 2 : 1
                rules.append(AutoSelectionRule(relativePath: relative, target: .children, coverage: .previousVersions(keep: keep)))
            }
        }
        rules += [
            AutoSelectionRule(relativePath: "Library/Android/sdk/system-images", target: .children, coverage: .previousVersions(keep: 1)),
            AutoSelectionRule(relativePath: "Library/Android/sdk/ndk", target: .children, coverage: .previousVersions(keep: 1)),
            AutoSelectionRule(
                relativePath: ".android/avd", target: .children, coverage: .unusedKeepingNewest,
                sidecarPairing: SidecarPairing(directorySuffix: ".avd", sidecarSuffix: ".ini")),
            AutoSelectionRule(relativePath: ".cache/lm-studio", target: .children, coverage: .unusedOnly),
            // Name-matched rebuildable folders anywhere in the scan; tier 2 only.
            AutoSelectionRule(relativePath: nil, target: .children, coverage: .none),
        ]
        return rules
    }
}

/// Pure tier decisions over one location's candidate children. Recency is the subtree's
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

    /// Tier-1 selection over one location's direct children. Symlinks and package
    /// internals never qualify; paired sidecars travel with their directory.
    public static func select(
        children: [FileNode], rule: AutoSelectionRule, tier: AutoSelectionTier, unusedBefore cutoff: Date
    ) -> [FileNode] {
        let primaries: [FileNode]
        var sidecarByName: [String: FileNode] = [:]
        if let pairing = rule.sidecarPairing {
            primaries = children.filter { $0.isDirectory && !$0.isSymbolicLink && !$0.packageAncestor && $0.name.hasSuffix(pairing.directorySuffix) }
            for child in children where !child.isDirectory {
                sidecarByName[child.name] = child
            }
        } else {
            primaries = children.filter { !$0.isSymbolicLink && !$0.packageAncestor }
        }
        let ranked = primaries.sorted { a, b in
            let left = a.latestContentModification ?? .distantPast
            let right = b.latestContentModification ?? .distantPast
            return left == right ? a.name > b.name : left > right
        }
        let selected: [FileNode]
        switch tier {
        case .regenerable:
            selected = ranked
        case .safe:
            switch rule.coverage {
            case .none:
                selected = []
            case .all:
                selected = ranked
            case .previousVersions(let keep):
                // Previous versions first; when the location has none, the long-unused
                // ones qualify instead of being kept as "the most recent".
                selected = ranked.count > keep
                    ? Array(ranked.dropFirst(keep))
                    : ranked.filter { isLongUnused($0, before: cutoff) }
            case .unusedKeepingNewest:
                selected = ranked.dropFirst(1).filter { isLongUnused($0, before: cutoff) }
            case .unusedOnly:
                selected = ranked.filter { isLongUnused($0, before: cutoff) }
            }
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
    public init(location: FileNode, nodes: [FileNode], coversAllChildren: Bool) {
        self.location = location
        self.nodes = nodes
        self.coversAllChildren = coversAllChildren
    }
}

/// Everything one tier selects over the current index, grouped per curated location.
public struct AutoSelectionResult: Sendable {
    public let groups: [AutoSelectionGroup]
    public init(groups: [AutoSelectionGroup]) { self.groups = groups }
    public var nodes: [FileNode] { groups.flatMap(\.nodes) }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.nodes.count } }
    public var knownBytes: Int64 { nodes.reduce(0) { $0 + $1.knownSize(for: .allocated) } }
    public var unknownCount: Int { nodes.reduce(0) { $0 + ($1.unknownAllocatedCount > 0 ? 1 : 0) } }
    public var isEmpty: Bool { groups.allSatisfy { $0.nodes.isEmpty } }
}

/// The honest estimate shown by the tier-2 warning before anything is selected.
public struct AutoSelectionPreview: Sendable, Equatable {
    public let items: Int
    public let knownBytes: Int64
    public init(items: Int, knownBytes: Int64) {
        self.items = items
        self.knownBytes = knownBytes
    }
    public init(_ result: AutoSelectionResult) {
        items = result.itemCount
        knownBytes = result.knownBytes
    }
}
