import CoreGraphics
import DiskCore

enum MapDirection: Sendable { case up, down, left, right }

/// Arrow-key movement between map tiles: the nearest selectable tile in the pressed
/// direction, preferring tiles at the same nesting depth (siblings and cousins) before
/// any depth. Pure geometry over the laid-out tiles.
enum MapKeyboardNavigator {
    static func selectable(_ tile: SceneTile) -> Bool { tile.entry.node != nil && tile.entry.kind != .unreached }

    static func next(from current: SceneTile?, in tiles: [SceneTile], direction: MapDirection) -> SceneTile? {
        let candidates = tiles.filter(selectable)
        guard let current else {
            // Nothing selected yet: start at the top-leading tile of the shallowest level.
            let depth = candidates.map(\.depth).min()
            return candidates.filter { $0.depth == depth }.min { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        }
        let others = candidates.filter { $0.id != current.id }
        let sameDepth = others.filter { $0.depth == current.depth }
        return best(from: current, in: sameDepth, direction) ?? best(from: current, in: others, direction)
    }

    private static func best(from current: SceneTile, in tiles: [SceneTile], _ direction: MapDirection) -> SceneTile? {
        let origin = CGPoint(x: current.rect.midX, y: current.rect.midY)
        return tiles.compactMap { tile -> (SceneTile, CGFloat)? in
            let dx = tile.rect.midX - origin.x, dy = tile.rect.midY - origin.y
            let (primary, secondary): (CGFloat, CGFloat) = switch direction {
            case .left: (-dx, dy)
            case .right: (dx, dy)
            case .up: (-dy, dx)
            case .down: (dy, dx)
            }
            guard primary > 1 else { return nil }
            return (tile, primary + 2 * abs(secondary))
        }.min { $0.1 < $1.1 }?.0
    }
}
