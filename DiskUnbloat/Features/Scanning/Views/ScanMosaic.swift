import SwiftUI

/// Decorative "living treemap" for the scanning screen. Everything here is a pure
/// function of wall-clock time — never of scanner updates — so short scans are not
/// delayed and a stalled scanner does not freeze or speed up the motion. Inactive
/// scenes and Reduce Motion pause it on a static, fully assembled frame; Reduce
/// Transparency drops the gradients, glow and light beam.
struct ScanMosaic: View {
    let active: Bool
    @State private var started = Date()
    static let size = CGSize(width: 380, height: 290)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { timeline in
            ScanMosaicFrame(active: active, time: active ? timeline.date.timeIntervalSince(started) : 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// One frame of the mosaic at a given time since it appeared.
struct ScanMosaicFrame: View {
    let active: Bool
    let time: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private static let mosaicFrame = CGRect(x: 40, y: 30, width: 300, height: 230)
    private static let colors: [Color] = [.teal, .cyan, .indigo, .mint, .blue, .teal, .cyan, .indigo, .mint]

    var body: some View {
        Canvas { context, _ in draw(&context, time: time) }.frame(width: ScanMosaic.size.width, height: ScanMosaic.size.height)
    }

    private func draw(_ context: inout GraphicsContext, time: Double) {
        let frame = Self.mosaicFrame
        let cells = ScanMosaicLayout.cells(in: frame, time: active ? time : 0)
        if !reduceTransparency {
            let breathe = active ? 0.5 + 0.5 * sin(time * 1.1) : 0.5
            // Fades to clear well inside the canvas, so no edge of the glow is ever visible.
            context.fill(Path(CGRect(origin: .zero, size: ScanMosaic.size)),
                         with: .radialGradient(Gradient(colors: [Color.teal.opacity(0.18 + 0.08 * breathe), Color.teal.opacity(0.05), .clear]),
                                               center: CGPoint(x: frame.midX, y: frame.midY), startRadius: 0, endRadius: 140))
        }
        let beamX = frame.minX - 70 + ScanMosaicLayout.fract(time / 2.8) * (frame.width + 140)
        var union = Path()
        for (index, base) in cells.enumerated() {
            let assembly = active ? ScanMosaicLayout.clamp((time - Double(index) * 0.06) / 0.6) : 1
            let eased = 1 - pow(1 - assembly, 3)
            let rect = base.offsetBy(dx: (1 - eased) * (index.isMultiple(of: 2) ? -26 : 26), dy: (1 - eased) * 18)
            let path = Path(roundedRect: rect, cornerRadius: min(12, rect.width / 3, rect.height / 3))
            union.addPath(path)
            let color = Self.colors[index % Self.colors.count]
            // Cells brighten as the reading beam passes over them.
            let lit = active && !reduceTransparency ? exp(-pow((rect.midX - beamX) / 70, 2)) * 0.2 : 0
            if reduceTransparency {
                context.fill(path, with: .color(color.opacity(eased)))
            } else {
                context.fill(path, with: .linearGradient(Gradient(colors: [color.opacity((0.78 + lit) * eased), color.opacity((0.32 + lit) * eased)]),
                                                         startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            }
            // Each cell "fills up" as if being measured, then resets, out of phase with its neighbours.
            if active {
                let level = ScanMosaicLayout.fract((time + Double(index) * 0.53) / 3.4)
                let height = rect.height * (1 - pow(1 - level, 2))
                let fade = 1 - ScanMosaicLayout.smoothstep(0.82, 1, level)
                var clipped = context
                clipped.clip(to: path)
                clipped.fill(Path(CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)),
                             with: .color(.white.opacity(0.11 * fade * eased)))
            }
            context.stroke(path, with: .color(.white.opacity(0.14 * eased)), lineWidth: 1)
        }
        guard active else { return }
        if !reduceTransparency {
            var beam = context
            beam.clip(to: union)
            beam.fill(Path(CGRect(x: beamX - 60, y: frame.minY, width: 120, height: frame.height)),
                      with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.2), .clear]),
                                            startPoint: CGPoint(x: beamX - 60, y: 0), endPoint: CGPoint(x: beamX + 60, y: 0)))
        }
        // "Files" flying in from outside and landing in a cell.
        for particle in ScanMosaicLayout.particles(time: time, cells: cells, around: frame) {
            let rect = CGRect(x: particle.position.x - particle.size / 2, y: particle.position.y - particle.size / 2, width: particle.size, height: particle.size)
            context.fill(Path(roundedRect: rect, cornerRadius: particle.size / 3),
                         with: .color(Self.colors[particle.cell % Self.colors.count].opacity(particle.opacity)))
        }
    }
}

/// Pure geometry for `ScanMosaic`, kept separate so its tiling can be tested.
enum ScanMosaicLayout {
    static let baseWeights: [Double] = [9, 5, 4, 7, 3, 4, 2.5, 3, 2]
    static let gap: CGFloat = 8

    /// Slice-and-dice tiling with a fixed split tree, so cells morph continuously as
    /// their weights oscillate instead of jumping between arrangements.
    static func cells(in bounds: CGRect, time: Double) -> [CGRect] {
        let weights = baseWeights.enumerated().map { index, base in
            base * (1 + 0.3 * sin(time * (0.55 + Double(index % 4) * 0.17) + Double(index) * 1.3))
        }
        var result = [CGRect](repeating: .zero, count: weights.count)
        split(weights, 0..<weights.count, bounds, vertical: bounds.width >= bounds.height, into: &result)
        return result.map { $0.insetBy(dx: gap / 2, dy: gap / 2) }
    }

    private static func split(_ weights: [Double], _ range: Range<Int>, _ rect: CGRect, vertical: Bool, into result: inout [CGRect]) {
        guard range.count > 1 else { if let index = range.first { result[index] = rect }; return }
        let mid = range.lowerBound + range.count / 2
        let left = weights[range.lowerBound..<mid].reduce(0, +), total = weights[range].reduce(0, +)
        let ratio = CGFloat(total > 0 ? left / total : 0.5)
        let (a, b) = vertical
            ? rect.divided(atDistance: rect.width * ratio, from: .minXEdge)
            : rect.divided(atDistance: rect.height * ratio, from: .minYEdge)
        split(weights, range.lowerBound..<mid, a, vertical: !vertical, into: &result)
        split(weights, mid..<range.upperBound, b, vertical: !vertical, into: &result)
    }

    struct Particle { let position: CGPoint; let size: CGFloat; let opacity: Double; let cell: Int }

    static func particles(time: Double, cells: [CGRect], around frame: CGRect, count: Int = 16) -> [Particle] {
        guard !cells.isEmpty else { return [] }
        let period = 1.9
        return (0..<count).compactMap { k in
            let shifted = time + Double(k) * period / Double(count)
            let cycle = floor(shifted / period), local = shifted / period - cycle
            let angle = random(Double(k), cycle) * 2 * .pi
            let radius = max(frame.width, frame.height) * 0.62
            let start = CGPoint(x: frame.midX + cos(angle) * radius, y: frame.midY + sin(angle) * radius * 0.8)
            let cell = (k + Int(cycle)) % cells.count
            let target = cells[cell]
            let end = CGPoint(x: target.minX + target.width * (0.25 + 0.5 * random(cycle, Double(k))),
                              y: target.minY + target.height * (0.25 + 0.5 * random(Double(k) + 7, cycle)))
            let travel = local * local
            let position = CGPoint(x: start.x + (end.x - start.x) * travel, y: start.y + (end.y - start.y) * travel)
            return Particle(position: position, size: 5 * (1 - 0.6 * local), opacity: sin(local * .pi) * 0.9, cell: cell)
        }
    }

    static func fract(_ value: Double) -> Double { value - floor(value) }
    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = clamp((value - edge0) / (edge1 - edge0)); return t * t * (3 - 2 * t)
    }
    /// Deterministic hash in 0..<1 so particle paths need no stored state.
    private static func random(_ a: Double, _ b: Double) -> Double { fract(sin(a * 12.9898 + b * 78.233) * 43758.5453) }
}
