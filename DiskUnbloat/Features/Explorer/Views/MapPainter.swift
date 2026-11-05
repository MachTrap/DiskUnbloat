import SwiftUI
import DiskCore

struct MapDrawing: View, Equatable {
    let tiles: [SceneTile]
    let style: MapTileStyle
    let labelDetail: MapLabelDetail
    var asynchronous = true
    @Environment(\.colorScheme) private var scheme
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.labelDetail == b.labelDetail && a.asynchronous == b.asynchronous && a.tiles == b.tiles && a.style == b.style
    }
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: asynchronous) { context, _ in
            for tile in tiles {
                let labels = MapLabelLayout.plan(for: tile, in: tile.rect, detail: labelDetail,
                                                 dimmed: style.dimmed(tile), context: context)
                MapPainter.draw(tile, in: tile.rect, opacity: 1, style: style, scheme: scheme, labels: labels, context: context)
            }
        }
    }
}

/// Frame-by-frame drawing of a `MapMorph`; shown only while the motion runs.
struct MorphingMapDrawing: View {
    let morph: MapMorph
    let start: Date
    let style: MapTileStyle
    let labelDetail: MapLabelDetail
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // The synchronous Canvas supplies the text environment on its first frame.
        // Retain the resolved plans for this timeline, not across morphs or restyles.
        let labels = MotionLabels()
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Canvas(opaque: false) { context, _ in
                if labels.plans == nil {
                    labels.plans = morph.items.map { item in
                        guard let rect = item.to ?? item.from else { return nil }
                        return MapLabelLayout.plan(for: item.tile, in: rect, detail: labelDetail,
                                                   dimmed: style.dimmed(item.tile), context: context)
                    }
                }
                for (item, label) in zip(morph.items, labels.plans ?? []) {
                    let state = morph.state(of: item, elapsed: elapsed)
                    guard state.opacity > 0.01 else { continue }
                    MapPainter.draw(item.tile, in: state.rect, opacity: state.opacity, style: style, scheme: scheme, labels: label, context: context)
                }
            }
        }
    }

    @MainActor
    private final class MotionLabels {
        var plans: [MapLabelLayout.Plan?]?
    }
}

enum MapPainter {
    /// Draws one tile. Colour comes from the active map colour mode's class; the legend
    /// highlight only dims other classes.
    static func draw(_ tile: SceneTile, in rect: CGRect, opacity: Double, style: MapTileStyle,
                     scheme: ColorScheme, labels: MapLabelLayout.Plan?, context base: GraphicsContext) {
        guard MapMorph.drawable(rect) else { return }
        var context = base
        context.opacity = opacity
        let entry = tile.entry
        let dimmed = style.dimmed(tile)
        let color = style.color(of: tile)
        let path = Path(roundedRect: rect, cornerRadius: tile.isContainer ? 7 : 5)
        if tile.isContainer {
            context.fill(path, with: .color(.primary.opacity(scheme == .dark ? 0.055 : 0.035)))
            context.stroke(path, with: .color(.primary.opacity(0.1)), lineWidth: 1)
        } else {
            let fill = dimmed ? 0.10 : scheme == .dark ? 0.68 : 0.27
            context.fill(path, with: .linearGradient(Gradient(colors: [color.opacity(fill), color.opacity(fill * 0.7)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            context.stroke(path, with: .color(color.opacity(dimmed ? 0.08 : 0.22)), lineWidth: 0.5)
        }
        if entry.kind == .unreached {
            // Hatched: this is space on the disk, not something the scan found.
            var hatch = context
            hatch.clip(to: path)
            var stripes = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX { stripes.move(to: CGPoint(x: x, y: rect.maxY)); stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY)); x += 10 }
            hatch.stroke(stripes, with: .color(.primary.opacity(0.08)), lineWidth: 3)
        }
        labels?.draw(in: rect, clippedTo: path, context: context)
    }
}
