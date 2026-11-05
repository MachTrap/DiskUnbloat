import SwiftUI
import DiskCore

/// What tile colour means on the map. Switching modes or highlighting a class only
/// restyles tiles; it never changes the scene or its geometry.
enum MapColorMode: String, CaseIterable, Identifiable {
    case safety, age, growth
    var id: Self { self }
    var title: String {
        switch self {
        case .safety: L10n.text("Cleanup safety")
        case .age: L10n.text("Last modified")
        case .growth: L10n.text("Growth")
        }
    }
    var classes: [TileClass] {
        switch self {
        case .safety: [.junk, .caches, .rebuildable, .deep, .containsReclaimable, .protected, .yours]
        case .age: [.month, .halfYear, .year, .twoYears, .older, .ageUnknown]
        case .growth: [.grew, .shrank, .added, .unchanged, .noHistory]
        }
    }
}

/// One legend entry. Safety classes come only from the curated quick-select rules and
/// the cleanup protections; age classes describe modification dates and never imply
/// that something is safe to delete.
enum TileClass: String, CaseIterable, Identifiable {
    case junk, caches, rebuildable, deep, containsReclaimable, protected, yours
    case month, halfYear, year, twoYears, older, ageUnknown
    case grew, shrank, added, unchanged, noHistory
    var id: Self { self }

    var title: String {
        switch self {
        case .junk: L10n.text("Junk")
        case .caches: L10n.text("Caches")
        case .rebuildable: L10n.text("Rebuildable")
        case .deep: L10n.text("Deep clean")
        case .containsReclaimable: L10n.text("Contains reclaimable")
        case .protected: L10n.text("Protected")
        case .yours: L10n.text("Your data")
        case .month: L10n.text("This month")
        case .halfYear: L10n.text("Within 6 months")
        case .year: L10n.text("Within a year")
        case .twoYears: L10n.text("Within 2 years")
        case .older: L10n.text("Older")
        case .ageUnknown: L10n.text("Unknown date")
        case .grew: L10n.text("Grew")
        case .shrank: L10n.text("Shrank")
        case .added: L10n.text("New")
        case .unchanged: L10n.text("Unchanged")
        case .noHistory: L10n.text("No earlier data")
        }
    }

    /// Hover-card explanation, kept honest: only safety classes speak about deletion.
    var explanation: String {
        switch self {
        case .junk: L10n.text("Selected by the Junk level: old versions, build data and known caches.")
        case .caches: L10n.text("Selected from the Caches level: apps rebuild these, sometimes signing you out.")
        case .rebuildable: L10n.text("Selected from the Rebuildable level: tools can download or rebuild it.")
        case .deep: L10n.text("Selected only by Deep clean: older app settings and long-unused installers.")
        case .containsReclaimable: L10n.text("Some items inside are selected by a quick-select level.")
        case .protected: L10n.text("Protected: DiskUnbloat never removes this.")
        case .yours: L10n.text("No quick-select level touches this. Review it yourself.")
        case .month, .halfYear, .year, .twoYears, .older: L10n.text("Newest content change inside. Age alone never makes something safe to delete.")
        case .ageUnknown: L10n.text("Some modification dates inside are unknown.")
        case .grew, .shrank, .added, .unchanged, .noHistory: ""
        }
    }

    var color: Color {
        switch self {
        case .junk: .green
        case .caches: .mint
        case .rebuildable: .cyan
        case .deep: .indigo
        case .containsReclaimable: .yellow
        case .protected: .red
        case .yours: .gray
        case .month: .blue
        case .halfYear: .teal
        case .year: .yellow
        case .twoYears: .orange
        case .older: .red
        case .ageUnknown: .gray
        case .grew: .orange
        case .shrank: .green
        case .added: .pink
        case .unchanged: .gray
        case .noHistory: Color(white: 0.55)
        }
    }
}

/// Classifies scene entries for the current mode. Pure: tested without views.
struct MapColoring {
    var mode: MapColorMode
    var safety: SafetyClassification
    var roots: [URL]
    var exemptCacheRoots: [String]
    var now = Date()
    /// Earlier size for (path, current bytes): `nil` result means new. The closure is
    /// `nil` when there is no earlier scan to compare with.
    var growth: ((String, Int64) -> Int64?)?

    func tileClass(_ entry: MapEntry) -> TileClass? {
        guard let node = entry.node else { return nil }
        switch mode {
        case .safety:
            if let level = safety.level(of: node.path) {
                switch level { case .junk: return .junk; case .caches: return .caches; case .rebuildable: return .rebuildable; case .deep: return .deep }
            }
            if node.isDirectory, safety.containsSelectable(below: node.path) { return .containsReclaimable }
            if CleanupSafety.blockedReasonCode(node, roots: roots, exemptingCacheRoots: exemptCacheRoots) != nil { return .protected }
            return .yours
        case .age:
            guard node.unknownModificationCount == 0, let date = node.latestContentModification ?? node.modified else { return .ageUnknown }
            let days = now.timeIntervalSince(date) / 86_400
            return days < 31 ? .month : days < 183 ? .halfYear : days < 366 ? .year : days < 731 ? .twoYears : .older
        case .growth:
            guard let growth else { return .noHistory }
            let bytes = entry.bytes
            guard let previous = growth(node.path, bytes) else { return .added }
            let threshold = max(Int64(1 << 20), previous / 20)
            return bytes - previous > threshold ? .grew : previous - bytes > threshold ? .shrank : .unchanged
        }
    }

    /// Classes for every node-backed entry of `scene`, plus each class's share of the
    /// leaf tiles' bytes (containers are frames, not storage, so they never count twice).
    func classify(_ scene: MapScene) -> (classes: [Int64: TileClass], shares: [TileClass: Int64]) {
        let parents = Set(scene.entries.map(\.parentID))
        var classes: [Int64: TileClass] = [:]; var shares: [TileClass: Int64] = [:]
        for entry in scene.entries {
            guard let tileClass = tileClass(entry) else { continue }
            classes[entry.id] = tileClass
            if !parents.contains(entry.id) { shares[tileClass, default: 0] += entry.bytes }
        }
        return (classes, shares)
    }
}

/// What the painter needs to colour tiles; equatable so the canvas redraws only on change.
/// How the search field acts on the map.
enum SearchMode: String, CaseIterable, Identifiable {
    /// Classic: the map shows only matching items (a filtered scene).
    case filter
    /// The map keeps its layout; matches and the folders containing them stay lit.
    case highlight
    var id: Self { self }
    var title: String { self == .filter ? L10n.text("Filter the map") : L10n.text("Highlight on the map") }
    var symbol: String { self == .filter ? "line.3.horizontal.decrease" : "highlighter" }
    static func matchCount(_ count: Int) -> String { count.formatted() }
}

/// Sorted match paths for highlight search: a tile is lit when it is a match or
/// contains one.
struct SearchHighlight: Equatable {
    private(set) var paths: [String] = []
    init(paths: [String] = []) { self.paths = paths.sorted() }
    func lights(_ path: String) -> Bool {
        let exact = lowerBound(path)
        if exact < paths.count, paths[exact] == path { return true }
        // Descendants sort from `path + "/"` on (siblings like "path-1" sort before it).
        let prefix = path + "/", below = lowerBound(prefix)
        return below < paths.count && paths[below].hasPrefix(prefix)
    }
    private func lowerBound(_ key: String) -> Int {
        var low = 0, high = paths.count
        while low < high { let mid = (low + high) / 2; if paths[mid] < key { low = mid + 1 } else { high = mid } }
        return low
    }
}

struct MapTileStyle: Equatable {
    var classes: [Int64: TileClass] = [:]
    var highlighted: TileClass?
    /// Tiles lit by a highlight search; `nil` when no highlight search is active.
    var searchLit: Set<Int64>?
    var mode: MapColorMode = .safety
    /// Changes when the user restyles (mode or highlight), so the canvas crossfades;
    /// scene reloads keep it, so navigation is not slowed by a fade.
    var crossfadeKey: String { mode.rawValue + "/" + (highlighted?.rawValue ?? "") + (searchLit == nil ? "" : "/search") }
    func tileClass(of tile: SceneTile) -> TileClass? { classes[tile.id] }
    func color(of tile: SceneTile) -> Color {
        switch tile.entry.kind {
        case .aggregate: return .gray
        case .unreached: return Color(white: 0.42)
        default: return classes[tile.id]?.color ?? .gray
        }
    }
    func dimmed(_ tile: SceneTile) -> Bool {
        guard !tile.isContainer else { return false }
        if let searchLit, !searchLit.contains(tile.id) { return true }
        guard let highlighted else { return false }
        return classes[tile.id] != highlighted
    }
}
