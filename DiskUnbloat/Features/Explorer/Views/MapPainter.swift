import SwiftUI
import DiskCore

struct MapDrawing: View, Equatable {
    let tiles: [SceneTile]
    let style: MapTileStyle
    var asynchronous = true
    @Environment(\.colorScheme) private var scheme
    nonisolated static func == (a: Self, b: Self) -> Bool { a.tiles == b.tiles && a.style == b.style && a.asynchronous == b.asynchronous }
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: asynchronous) { context, _ in
            for tile in tiles { MapPainter.draw(tile, in: tile.rect, opacity: 1, style: style, scheme: scheme, context: context) }
        }
    }
}

/// Frame-by-frame drawing of a `MapMorph`; shown only while the motion runs.
struct MorphingMapDrawing: View {
    let morph: MapMorph
    let start: Date
    let style: MapTileStyle
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Canvas(opaque: false) { context, _ in
                for item in morph.items {
                    let state = morph.state(of: item, elapsed: elapsed)
                    guard state.opacity > 0.01 else { continue }
                    MapPainter.draw(item.tile, in: state.rect, opacity: state.opacity, style: style, scheme: scheme, context: context)
                }
            }
        }
    }
}

enum MapPainter {
    /// Draws one tile. Colour comes from the active map colour mode's class; the legend
    /// highlight only dims other classes.
    static func draw(_ tile: SceneTile, in rect: CGRect, opacity: Double, style: MapTileStyle, scheme: ColorScheme, context base: GraphicsContext) {
        guard rect.width > 1, rect.height > 1 else { return }
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
        guard rect.width > 62 && rect.height > 23 else { return }
        let foreground: Color = dimmed ? .secondary.opacity(0.4) : .primary
        let label = Text(entry.localizedTitle).font(.system(size: tile.isContainer ? 11 : 12, weight: .medium)).foregroundStyle(foreground)
        context.draw(label, in: CGRect(x: rect.minX + 9, y: rect.minY + 5, width: rect.width - 18, height: 16))
        if !tile.isContainer && rect.height > 54 && rect.width > 85 {
            context.draw(Text(sizeText(entry.bytes)).font(.system(size: 11)).foregroundStyle(foreground.opacity(0.65)), at: CGPoint(x: rect.minX + 9, y: rect.minY + 27), anchor: .topLeading)
            if entry.unknownCount > 0 && rect.height > 78 {
                context.draw(Text("Partial size").font(.system(size: 10)).foregroundStyle(.orange), at: CGPoint(x: rect.minX + 9, y: rect.minY + 46), anchor: .topLeading)
            }
        }
    }
}
