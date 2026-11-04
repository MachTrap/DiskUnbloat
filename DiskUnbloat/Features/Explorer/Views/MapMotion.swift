import CoreGraphics
import DiskCore

/// One decorative transition between two map layouts. It only changes how tiles are
/// drawn for a fraction of a second; hit-testing, selection and queue state always use
/// the final layout, so a click during the motion lands on the tile it will settle as.
struct MapMorph {
    struct Item {
        let tile: SceneTile
        /// Where the tile starts; `nil` grows it in from its own center.
        let from: CGRect?
        /// Where the tile ends; `nil` shrinks it away (it left the layout).
        let to: CGRect?
        let delay: Double
    }

    let items: [Item]
    let duration: Double
    /// Always finite and short: delays are clamped when items are built.
    var totalDuration: Double { duration + (items.map(\.delay).max() ?? 0) }
    static let maxDelay = 0.4

    /// Tiles the painter would skip (the layout can emit `CGRect.null`, whose origin is
    /// infinite, or sub-pixel rects) never take part in motion.
    static func drawable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 1 && rect.height > 1
    }

    /// Beyond this many tiles a frame-by-frame redraw costs more than it is worth;
    /// such layouts swap instantly.
    static let tileLimit = 2500

    /// Same root, new geometry (filters, size metric, queued items hidden): tiles glide
    /// from their old rectangles, newcomers grow in and departing tiles shrink away.
    static func relayout(from old: [SceneTile], to new: [SceneTile]) -> MapMorph? {
        guard !old.isEmpty, !new.isEmpty, old.count + new.count <= tileLimit * 2,
              max(old.count, new.count) <= tileLimit, old != new else { return nil }
        let old = old.filter { drawable($0.rect) }, new = new.filter { drawable($0.rect) }
        guard !old.isEmpty, !new.isEmpty else { return nil }
        let previous = Dictionary(old.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(new.map(\.id))
        let leaving = old.filter { !kept.contains($0.id) }.map { Item(tile: $0, from: $0.rect, to: nil, delay: 0) }
        let staying = new.map { Item(tile: $0, from: previous[$0.id], to: $0.rect, delay: previous[$0.id] == nil ? 0.08 : 0) }
        return MapMorph(items: leaving + staying, duration: 0.34)
    }

    /// First appearance (or a fresh folder): every tile grows in, swept diagonally from
    /// the top-leading corner so the map reads as assembling rather than popping.
    static func intro(_ tiles: [SceneTile], in size: CGSize, sweep: Double = 0.22) -> MapMorph? {
        guard !tiles.isEmpty, tiles.count <= tileLimit, size.width > 0, size.height > 0 else { return nil }
        let tiles = tiles.filter { drawable($0.rect) }
        guard !tiles.isEmpty else { return nil }
        let span = size.width + size.height
        let sweep = min(max(0, sweep), maxDelay)
        return MapMorph(items: tiles.map { tile in
            let position = Double((tile.rect.minX + tile.rect.minY) / span)
            return Item(tile: tile, from: nil, to: tile.rect, delay: sweep * min(1, max(0, position)))
        }, duration: 0.36)
    }

    /// Rectangle and opacity of `item` `elapsed` seconds into the motion.
    func state(of item: Item, elapsed: Double) -> (rect: CGRect, opacity: Double) {
        let raw = min(1, max(0, (elapsed - item.delay) / duration))
        switch (item.from, item.to) {
        case let (from?, to?):
            let t = Self.easeInOut(raw)
            return (Self.interpolate(from, to, t), 1)
        case let (nil, to?):
            let t = Self.easeOut(raw)
            return (Self.scaled(to, by: 0.55 + 0.45 * t), t)
        case let (from?, nil):
            let t = Self.easeOut(raw)
            return (Self.scaled(from, by: 1 - 0.45 * t), 1 - t)
        case (nil, nil):
            return (.zero, 0)
        }
    }

    static func interpolate(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        let t = CGFloat(t)
        return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
    static func scaled(_ rect: CGRect, by factor: Double) -> CGRect {
        let f = CGFloat(factor)
        return CGRect(x: rect.midX - rect.width * f / 2, y: rect.midY - rect.height * f / 2, width: rect.width * f, height: rect.height * f)
    }
    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
}

/// Spatial focus navigation: zooming into a folder blows its old tile up to fill the
/// view, and going up shrinks the old view back into the tile it now occupies.
enum MapZoom {
    /// The frame a snapshot of the whole view must take so that `focus` (in that
    /// snapshot's coordinates) exactly covers `bounds`.
    static func expanded(focus: CGRect, bounds: CGSize) -> CGRect? {
        guard focus.width > 1, focus.height > 1 else { return nil }
        let sx = bounds.width / focus.width, sy = bounds.height / focus.height
        return CGRect(x: -focus.minX * sx, y: -focus.minY * sy, width: bounds.width * sx, height: bounds.height * sy)
    }
}
