import Foundation
import CoreGraphics
public struct MapTile: Identifiable, Sendable {
    public let id: Int64
    public let rect: CGRect
    public let node: FileNode?
    public let count: Int
    public init(id: Int64, rect: CGRect, node: FileNode?, count: Int = 1) { self.id = id; self.rect = rect; self.node = node; self.count = count }
}
public enum Treemap {
    @concurrent public static func layoutAsync(_ nodes: [FileNode], in bounds: CGRect, metric: SizeMetric = .allocated) async -> [MapTile] { layout(nodes, in: bounds, metric: metric) }
    public static func layout(_ nodes: [FileNode], in bounds: CGRect, metric: SizeMetric = .allocated, minimumArea: Double = 36) -> [MapTile] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let positive = nodes.filter { $0.size(for: metric) ?? 0 > 0 }.sorted { ($0.size(for: metric) ?? 0) > ($1.size(for: metric) ?? 0) }
        let total = positive.reduce(0.0) { $0 + Double($1.size(for: metric) ?? 0) }
        guard total > 0 else { return [] }
        let scale = bounds.width * bounds.height / total
        var entries: [(FileNode?, Double, Int)] = []; var tiny = 0.0; var tinyCount = 0
        for n in positive {
            let area = Double(n.size(for: metric) ?? 0) * scale
            if area < minimumArea { tiny += area; tinyCount += 1 } else { entries.append((n, area, 1)) }
        }
        if tiny > 0 { entries.append((nil, tiny, tinyCount)) }
        var remaining = bounds; var row: [(FileNode?, Double, Int)] = []; var result: [MapTile] = []
        var rowSum = 0.0; var rowMin = Double.infinity; var rowMax = 0.0
        func worst(sum: Double, smallest: Double, largest: Double, edge: Double) -> Double {
            guard sum > 0, edge > 0, smallest > 0 else { return .infinity }
            return max(edge * edge * largest / (sum * sum), sum * sum / (edge * edge * smallest))
        }
        func place(_ row: [(FileNode?, Double, Int)]) {
            let area = row.reduce(0) { $0 + $1.1 }; let vertical = remaining.width >= remaining.height
            let edge = vertical ? remaining.height : remaining.width
            guard edge > 0 else { return }
            let thickness = area / edge; var offset = 0.0
            for entry in row {
                let length = entry.1 / thickness
                let rect = vertical ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length) : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                result.append(MapTile(id: entry.0?.id ?? -1, rect: rect, node: entry.0, count: entry.2)); offset += length
            }
            if vertical { remaining.origin.x += thickness; remaining.size.width -= thickness }
            else { remaining.origin.y += thickness; remaining.size.height -= thickness }
        }
        for entry in entries {
            let edge = min(remaining.width, remaining.height)
            if !row.isEmpty && worst(sum: rowSum + entry.1, smallest: min(rowMin, entry.1), largest: max(rowMax, entry.1), edge: edge) > worst(sum: rowSum, smallest: rowMin, largest: rowMax, edge: edge) {
                place(row); row = []; rowSum = 0; rowMin = .infinity; rowMax = 0
            }
            row.append(entry); rowSum += entry.1; rowMin = min(rowMin, entry.1); rowMax = max(rowMax, entry.1)
        }
        if !row.isEmpty { place(row) }; return result
    }
}
