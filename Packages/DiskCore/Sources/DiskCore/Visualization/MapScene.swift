import Foundation
import CoreGraphics

public struct MapEntry: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable { case folder, file, aggregate }
    public let id: Int64
    public let parentID: Int64
    public let ownerID: Int64
    public let kind: Kind
    public let node: FileNode?
    public let bytes: Int64
    public let count: Int
    public let unknownCount: Int
    public var category: FileCategory { node?.category ?? .other }
    public var title: String { node?.name ?? "\(count.formatted()) more items" }
    public init(id: Int64, parentID: Int64, ownerID: Int64, kind: Kind, node: FileNode?, bytes: Int64, count: Int = 1, unknownCount: Int = 0) {
        self.id = id; self.parentID = parentID; self.ownerID = ownerID; self.kind = kind
        self.node = node; self.bytes = bytes; self.count = count; self.unknownCount = unknownCount
    }
}
public struct MapScene: Sendable, Equatable {
    public let rootID: Int64
    public let entries: [MapEntry]
    public let summary: SizeSummary
    public init(rootID: Int64 = 1, entries: [MapEntry] = [], summary: SizeSummary = SizeSummary()) {
        self.rootID = rootID; self.entries = entries; self.summary = summary
    }
}
public struct SceneTile: Identifiable, Sendable, Equatable {
    public var id: Int64 { entry.id }
    public let entry: MapEntry
    public let rect: CGRect
    public let depth: Int
    public let isContainer: Bool
    public var headerHeight: CGFloat { isContainer ? 24 : 0 }
}

extension ScanIndex {
    /// Bounded breadth-first loading keeps the current folder complete even on million-entry scans.
    public func mapScene(rootID: Int64, query: FileQuery, filtered: Bool, maxEntries: Int = 10000) -> MapScene {
        let budget = max(2, min(10000, maxEntries))
        // Queued (hidden) subtrees are excluded from container sizes so queued items visibly
        // disappear and their containers shrink. Each queued item's aggregate is its subtree size.
        // Every hidden record contributes its bytes to each of its ancestor keys once, so a
        // container's subtraction is a single dictionary lookup instead of a scan over the
        // whole queue per row (a bulk selection queues thousands).
        var queuedWithin: [String: Int64] = [:]
        func add(_ bytes: Int64, along path: String) {
            guard bytes > 0 else { return }
            var cursor = path
            while true {
                queuedWithin[cursor, default: 0] += bytes
                let parent = URL(fileURLWithPath: cursor).deletingLastPathComponent().path
                if parent == cursor { break }
                cursor = parent
            }
        }
        for path in query.hiddenPaths {
            if let n = node(path: path) { add(n.knownSize(for: query.metric), along: n.path) }
        }
        // Fully collapsed containers: their queued direct children were removed from
        // `hiddenPaths`, but their bytes still leave their ancestors — the container's
        // own tile and every folder above it lose exactly the queued children's sizes,
        // matching the queue's estimate.
        for subtree in query.hiddenSubtrees {
            let bytes = queuedChildBytes(ofSubtree: subtree, metric: query.metric)
            if bytes > 0 { add(bytes, along: subtree) }
        }
        func visibleSize(_ n: FileNode) -> Int64 {
            max(0, n.knownSize(for: query.metric) - (queuedWithin[n.path] ?? 0))
        }
        guard let rootNode = node(rootID) else { return MapScene(rootID: rootID, entries: [], summary: SizeSummary()) }
        var entries: [MapEntry] = []
        var pending: [(Int64, Int, FileNode)] = [(rootID, 0, rootNode)]
        var cursor = 0
        var rootSummary = SizeSummary()
        while cursor < pending.count {
            let (owner, depth, ownerNode) = pending[cursor]; cursor += 1
            var q = query
            if !filtered { q.parentID = owner; q.subtreePath = nil; q.leafResults = false }
            q.offset = 0
            // Reserve room for aggregates and upcoming branches. A folder may remain an atomic tile.
            let available = budget - entries.count
            guard available >= 2 else { break }
            q.limit = min(256, available - 1)
            q.sortByName = false; q.ascending = false
            let total = summary(q)
            if owner == rootID {
                let unknown = filtered ? total.unknownCount : max(total.unknownCount, rootNode.unknownCount(for: query.metric))
                rootSummary = SizeSummary(knownBytes: filtered ? total.knownBytes : visibleSize(rootNode), itemCount: total.itemCount, unknownCount: unknown)
            }
            let nodes = self.query(q)
            for node in nodes {
                let folder = node.isBrowsable(inspectPackages: query.inspectPackages)
                entries.append(MapEntry(id: node.id, parentID: owner, ownerID: owner, kind: folder ? .folder : .file, node: node, bytes: visibleSize(node), unknownCount: node.unknownCount(for: query.metric)))
                if folder && depth < 2 && !filtered && node.knownSize(for: query.metric) > 0 { pending.append((node.id, depth + 1, node)) }
            }
            let omitted = total.itemCount - nodes.count
            if omitted > 0 {
                let used = nodes.reduce(Int64(0)) { $0 + visibleSize($1) }
                let ownerBytes = filtered ? total.knownBytes : visibleSize(ownerNode)
                entries.append(MapEntry(id: -owner - 1, parentID: owner, ownerID: owner, kind: .aggregate, node: nil, bytes: max(0, ownerBytes - used), count: omitted, unknownCount: max(0,total.unknownCount - nodes.reduce(0) { $0 + $1.unknownCount(for: query.metric) })))
            }
            if filtered { break }
        }
        return MapScene(rootID: rootID, entries: entries, summary: rootSummary)
    }

    /// The known-size sum of every direct child of a collapsed container — the bytes those
    /// queued children take out of the container itself and every ancestor folder. Children
    /// are paged because a collapsed store can hold thousands of entries.
    private func queuedChildBytes(ofSubtree path: String, metric: SizeMetric) -> Int64 {
        guard let container = node(path: path) else { return 0 }
        var bytes: Int64 = 0
        var offset = 0
        while true {
            let page = children(of: container.id, inspectPackages: false, limit: 512, offset: offset)
            bytes += page.reduce(Int64(0)) { $0 + $1.knownSize(for: metric) }
            if page.count < 512 { return bytes }
            offset += page.count
        }
    }
}

public enum NestedTreemap {
    @concurrent public static func layout(_ scene: MapScene, in bounds: CGRect) async -> [SceneTile] { layoutSync(scene, in: bounds) }
    public static func layoutSync(_ scene: MapScene, in bounds: CGRect) -> [SceneTile] {
        let children = Dictionary(grouping: scene.entries, by: \.parentID)
        var tiles: [SceneTile] = []
        func place(owner: Int64, bounds: CGRect, depth: Int) {
            guard bounds.width > 2, bounds.height > 2, let all = children[owner] else { return }
            let positive = all.filter { $0.bytes > 0 }
            let sum = positive.reduce(0.0) { $0 + Double($1.bytes) }
            guard sum > 0 else { return }
            let scale = bounds.width * bounds.height / sum
            var visible: [MapEntry] = []; var aggregateBytes: Int64 = 0; var count = 0; var unknown = 0
            for entry in positive {
                if Double(entry.bytes) * scale < 32 || entry.kind == .aggregate {
                    aggregateBytes += entry.bytes; count += entry.count; unknown += entry.unknownCount
                } else { visible.append(entry) }
            }
            if aggregateBytes > 0 { visible.append(MapEntry(id: -owner - 1, parentID: owner, ownerID: owner, kind: .aggregate, node: nil, bytes: aggregateBytes, count: count, unknownCount: unknown)) }
            let lookup = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
            let nodes = visible.map { e in FileNode(id: e.id, parentID: owner, path: "", name: e.title, isDirectory: false, logicalSize: e.bytes, allocatedSize: e.bytes, modified: nil, identity: "") }
            for tile in Treemap.layout(nodes, in: bounds, minimumArea: 0) {
                guard let entry = lookup[tile.id] else { continue }
                let r = tile.rect.insetBy(dx: 1.5, dy: 1.5)
                let container = entry.kind == .folder && children[entry.id] != nil && r.width > 110 && r.height > 88 && depth < 3
                tiles.append(SceneTile(entry: entry, rect: r, depth: depth, isContainer: container))
                if container { place(owner: entry.id, bounds: CGRect(x: r.minX + 3, y: r.minY + 26, width: r.width - 6, height: r.height - 29), depth: depth + 1) }
            }
        }
        place(owner: scene.rootID, bounds: bounds, depth: 0)
        return tiles
    }
    public static func hitTest(_ point: CGPoint, tiles: [SceneTile]) -> SceneTile? { tiles.last { $0.rect.contains(point) } }
}
