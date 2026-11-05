import SwiftUI
import DiskCore

/// Hover highlight that glides between tiles, plus the ring "ping" on a single new
/// selection. Decorative only: never hit-tested, and still under Reduce Motion.
struct MapMotionOverlay: View {
    let hovered: SceneTile?
    let ping: CGRect?
    let pingToken: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.clear.overlay(alignment: .topLeading) {
                if let hovered {
                    let shape = RoundedRectangle(cornerRadius: hovered.isContainer ? 7 : 5)
                    shape.fill(.primary.opacity(hovered.isContainer ? 0.03 : 0.07))
                        .overlay(shape.strokeBorder(.primary.opacity(0.55), lineWidth: 1.5))
                        .frame(width: hovered.rect.width, height: hovered.rect.height)
                        .offset(x: hovered.rect.minX, y: hovered.rect.minY)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: hovered?.id)
            Color.clear.overlay(alignment: .topLeading) {
                if let ping {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(Color.teal, lineWidth: 3)
                        .frame(width: ping.width, height: ping.height)
                        .keyframeAnimator(initialValue: PingValue(), trigger: pingToken) { content, value in
                            content.scaleEffect(value.scale).opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) { CubicKeyframe(1, duration: 0.01); CubicKeyframe(1.06, duration: 0.45) }
                            KeyframeTrack(\.opacity) { LinearKeyframe(0.9, duration: 0.06); LinearKeyframe(0, duration: 0.4) }
                        }
                        .offset(x: ping.minX, y: ping.minY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private struct PingValue { var scale = 1.0; var opacity = 0.0 }
}
