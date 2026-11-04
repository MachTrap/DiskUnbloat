import CoreGraphics
import Testing
import DiskCore
@testable import DiskUnbloat

/// Decorative motion must start from what was on screen and settle exactly on the final
/// layout, so the frame drawn at the end matches what hit-testing already uses.
struct MapMotionTests {
    private func tile(_ id: Int64, _ rect: CGRect) -> SceneTile {
        SceneTile(entry: MapEntry(id: id, parentID: 0, ownerID: 0, kind: .file, node: nil, bytes: 10), rect: rect, depth: 1, isContainer: false)
    }

    @Test func relayoutGlidesKeptTilesAndSettlesOnTheNewLayout() throws {
        let old = [tile(1, CGRect(x: 0, y: 0, width: 100, height: 50)), tile(2, CGRect(x: 100, y: 0, width: 100, height: 50))]
        let new = [tile(1, CGRect(x: 0, y: 0, width: 150, height: 50)), tile(3, CGRect(x: 150, y: 0, width: 50, height: 50))]
        let morph = try #require(MapMorph.relayout(from: old, to: new))
        let kept = try #require(morph.items.first { $0.tile.id == 1 && $0.to != nil })
        #expect(morph.state(of: kept, elapsed: 0).rect == old[0].rect)
        #expect(morph.state(of: kept, elapsed: morph.totalDuration).rect == new[0].rect)
        // The departing tile ends invisible; the newcomer ends fully opaque in place.
        let leaving = try #require(morph.items.first { $0.tile.id == 2 })
        #expect(leaving.to == nil && morph.state(of: leaving, elapsed: morph.totalDuration).opacity == 0)
        let arriving = try #require(morph.items.first { $0.tile.id == 3 })
        #expect(arriving.from == nil)
        let settled = morph.state(of: arriving, elapsed: morph.totalDuration)
        #expect(settled.rect == new[1].rect && settled.opacity == 1)
    }

    @Test func identicalOrOversizedLayoutsSwapWithoutMotion() {
        let same = [tile(1, CGRect(x: 0, y: 0, width: 10, height: 10))]
        #expect(MapMorph.relayout(from: same, to: same) == nil)
        let huge = (0..<Int64(MapMorph.tileLimit + 1)).map { tile($0, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        #expect(MapMorph.relayout(from: same, to: huge) == nil)
        #expect(MapMorph.intro(huge, in: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func introSweepsFromTheTopLeadingCorner() throws {
        let tiles = [tile(1, CGRect(x: 0, y: 0, width: 50, height: 50)), tile(2, CGRect(x: 150, y: 100, width: 50, height: 50))]
        let morph = try #require(MapMorph.intro(tiles, in: CGSize(width: 200, height: 150)))
        #expect(morph.items[0].delay < morph.items[1].delay)
        for item in morph.items {
            let settled = morph.state(of: item, elapsed: morph.totalDuration)
            #expect(settled.rect == item.to && settled.opacity == 1)
        }
    }

    /// Regression: the layout can emit `CGRect.null` (infinite origin) for empty tiles;
    /// that once made the motion's duration infinite and crashed converting it to a `Duration`.
    @Test func nullAndDegenerateRectsNeverMakeTheMotionInfinite() throws {
        let tiles = [tile(1, CGRect(x: 0, y: 0, width: 50, height: 50)), tile(2, .null), tile(3, .infinite), tile(4, CGRect(x: 10, y: 10, width: 0, height: 0))]
        let intro = try #require(MapMorph.intro(tiles, in: CGSize(width: 296, height: 335)))
        #expect(intro.items.map(\.tile.id) == [1])
        #expect(intro.totalDuration.isFinite && intro.totalDuration <= 1)
        let relayout = try #require(MapMorph.relayout(from: tiles, to: [tile(1, CGRect(x: 0, y: 0, width: 80, height: 50)), tile(5, .null)]))
        #expect(relayout.totalDuration.isFinite && relayout.items.allSatisfy { MapMorph.drawable($0.to ?? $0.from!) })
        #expect(MapMorph.intro([tile(2, .null)], in: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func zoomBlowsTheFocusedTileUpToTheWholeView() throws {
        let bounds = CGSize(width: 400, height: 300)
        let focus = CGRect(x: 100, y: 60, width: 200, height: 100)
        let frame = try #require(MapZoom.expanded(focus: focus, bounds: bounds))
        // Mapping the focus rect through the snapshot's new frame covers the view exactly.
        let sx = frame.width / bounds.width, sy = frame.height / bounds.height
        #expect(frame.minX + focus.minX * sx == 0 && frame.minY + focus.minY * sy == 0)
        #expect(focus.width * sx == bounds.width && focus.height * sy == bounds.height)
        #expect(MapZoom.expanded(focus: .zero, bounds: bounds) == nil)
    }

    @Test func scanMosaicTilesItsBoundsAtEveryMoment() {
        let bounds = CGRect(x: 40, y: 30, width: 300, height: 230)
        let gap = ScanMosaicLayout.gap
        for time in stride(from: 0.0, through: 40, by: 1.7) {
            let cells = ScanMosaicLayout.cells(in: bounds, time: time)
            #expect(cells.count == ScanMosaicLayout.baseWeights.count)
            // Re-adding each cell's gap recovers the tiled area: no holes, no overlap.
            let area = cells.reduce(0) { $0 + ($1.width + gap) * ($1.height + gap) }
            #expect(abs(area - bounds.width * bounds.height) < 0.5)
            #expect(cells.allSatisfy { $0.width > 4 && $0.height > 4 && bounds.insetBy(dx: -0.01, dy: -0.01).contains($0) })
        }
    }
}
