import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

struct MapInputTests {
    @Test func horizontalHistoryIsOncePerGestureAndIgnoresVerticalMomentum() {
        var input = MapHistoryGesture()
        #expect(input.scroll(x: 10,y: 100,began: true,precise: true,momentum: false,timestamp: 1) == nil)
        #expect(input.scroll(x: 100,y: 2,began: true,precise: true,momentum: true,timestamp: 2) == nil)
        #expect(input.scroll(x: 75,y: 2,began: true,precise: true,momentum: false,timestamp: 3) == true)
        #expect(input.scroll(x: 75,y: 2,began: false,precise: true,momentum: false,timestamp: 4) == nil)
        #expect(input.swipe(x: 1,y: 0,timestamp: 3.1) == nil)
        #expect(input.scroll(x: -75,y: 2,began: true,precise: true,momentum: false,timestamp: 5) == false)
        #expect(input.swipe(x: 1,y: 0,timestamp: 6) == true)
    }
}
