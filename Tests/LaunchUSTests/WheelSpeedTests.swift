import Foundation
import Testing
@testable import LaunchUS

@Suite struct WheelSpeedTests {
    @Test func slowNeedsMoreNotchesAndLongerGaps() {
        #expect(WheelSpeed.notches(0) == 4)
        #expect(WheelSpeed.notches(0.5) == 1)
        #expect(WheelSpeed.notches(1) == 1)
        #expect(WheelSpeed.interval(0) > WheelSpeed.interval(0.5))
        #expect(WheelSpeed.interval(0.5) > WheelSpeed.interval(1))
        #expect(abs(WheelSpeed.interval(0.5) - 0.6) < 0.001)
        #expect(WheelSpeed.pause(0) > WheelSpeed.pause(1))
    }

    @Test func onlyTheFastEndKeepsFlippingWithinASpin() {
        #expect(!WheelSpeed.repeats(0))
        #expect(!WheelSpeed.repeats(0.5))
        #expect(WheelSpeed.repeats(1))
    }

    @Test func gapsNeverGoNegative() {
        for s in stride(from: 0.0, through: 1, by: 0.05) {
            #expect(WheelSpeed.interval(s) > 0.1)
            #expect(WheelSpeed.pause(s) > 0.1)
        }
    }
}
