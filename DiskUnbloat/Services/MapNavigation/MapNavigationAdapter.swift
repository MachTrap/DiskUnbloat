import SwiftUI
import AppKit

/// Local monitor only; never observes other apps or requires accessibility permission.
struct MapNavigationAdapter: NSViewRepresentable {
    let back: () -> Void
    let forward: () -> Void
    func makeNSView(context: Context) -> NavigationView { NavigationView() }
    func updateNSView(_ view: NavigationView, context: Context) { view.back = back; view.forward = forward }

    final class NavigationView: NSView {
        var back: () -> Void = {}
        var forward: () -> Void = {}
        private var monitor: Any?
        private var gesture = MapHistoryGesture()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .otherMouseUp]) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      window.attachedSheet == nil else { return event }
                if event.type == .otherMouseUp {
                    if event.buttonNumber == 3 { self.back(); return nil }
                    if event.buttonNumber == 4 { self.forward(); return nil }
                    return event
                }
                let backwards: Bool?
                if event.type == .swipe {
                    backwards = self.gesture.swipe(x: event.deltaX,y: event.deltaY,timestamp: event.timestamp)
                } else {
                    backwards = self.gesture.scroll(x: event.scrollingDeltaX,y: event.scrollingDeltaY,began: event.phase.contains(.began),precise: event.hasPreciseScrollingDeltas,momentum: !event.momentumPhase.isEmpty,timestamp: event.timestamp)
                }
                if let backwards {
                    if backwards { self.back() } else { self.forward() }
                    return nil
                }
                return event
            }
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
