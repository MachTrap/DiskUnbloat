import CoreGraphics
import Testing
import DiskCore
@testable import DiskUnbloat

/// Arrow keys move to the nearest selectable tile in that direction, siblings first,
/// and never land on the unreached tile or a "more items" aggregate.
struct MapKeyboardNavigatorTests {
    private func tile(_ id: Int64, _ x: CGFloat, _ y: CGFloat, depth: Int = 1, kind: MapEntry.Kind = .file) -> SceneTile {
        let node = kind == .file ? FileNode(id: id, parentID: 1, path: "/m/\(id)", name: "\(id)", isDirectory: false, logicalSize: 1, allocatedSize: 1, modified: nil, identity: "\(id)") : nil
        return SceneTile(entry: MapEntry(id: id, parentID: 1, ownerID: 1, kind: kind, node: node, bytes: 1), rect: CGRect(x: x, y: y, width: 100, height: 100), depth: depth, isContainer: false)
    }

    @Test func movesToTheNearestTileInEachDirection() {
        let a = tile(1, 0, 0), b = tile(2, 110, 0), c = tile(3, 0, 110), d = tile(4, 110, 110)
        let tiles = [a, b, c, d]
        #expect(MapKeyboardNavigator.next(from: a, in: tiles, direction: .right)?.id == 2)
        #expect(MapKeyboardNavigator.next(from: a, in: tiles, direction: .down)?.id == 3)
        #expect(MapKeyboardNavigator.next(from: d, in: tiles, direction: .up)?.id == 2)
        #expect(MapKeyboardNavigator.next(from: d, in: tiles, direction: .left)?.id == 3)
        #expect(MapKeyboardNavigator.next(from: a, in: tiles, direction: .left) == nil)
        // Nothing selected: start top-leading.
        #expect(MapKeyboardNavigator.next(from: nil, in: tiles, direction: .down)?.id == 1)
    }

    @Test func prefersSameDepthAndSkipsUnselectableTiles() {
        let a = tile(1, 0, 0, depth: 2), nested = tile(2, 105, 0, depth: 3), cousin = tile(3, 300, 0, depth: 2)
        let unreached = tile(9, 120, 0, kind: .unreached), aggregate = tile(8, 130, 0, kind: .aggregate)
        let next = MapKeyboardNavigator.next(from: a, in: [a, nested, cousin, unreached, aggregate], direction: .right)
        #expect(next?.id == 3)
        #expect(MapKeyboardNavigator.next(from: a, in: [a, nested], direction: .right)?.id == 2)
    }
}
