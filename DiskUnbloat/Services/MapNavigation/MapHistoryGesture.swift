import Foundation

/// Transient input state, independent of filesystem and observable explorer state.
struct MapHistoryGesture {
    private var x = 0.0
    private var y = 0.0
    private var triggered = false
    private var lastNavigation = -Double.infinity

    mutating func scroll(x deltaX: Double, y deltaY: Double, began: Bool, precise: Bool, momentum: Bool, timestamp: Double) -> Bool? {
        guard precise, !momentum else { return nil }
        if began { x = 0; y = 0; triggered = false }
        x += deltaX; y += deltaY
        guard !triggered, abs(x) >= 70, abs(x) > abs(y) * 2 else { return nil }
        triggered = true
        return navigation(backwards: x > 0, timestamp: timestamp)
    }

    mutating func swipe(x: Double, y: Double, timestamp: Double) -> Bool? {
        guard abs(x) > abs(y), x != 0 else { return nil }
        return navigation(backwards: x > 0, timestamp: timestamp)
    }

    private mutating func navigation(backwards: Bool, timestamp: Double) -> Bool? {
        // A system swipe can also finish a scroll sequence; do not navigate twice.
        guard timestamp - lastNavigation > 0.3 else { return nil }
        lastNavigation = timestamp
        return backwards
    }
}
