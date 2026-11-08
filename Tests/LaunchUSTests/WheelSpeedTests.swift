import Foundation
import Testing
@testable import LaunchUS

@Suite struct WheelSpeedTests {
    @Test func notchesPerPageGoFromSixToOne() {
        #expect(abs(WheelSpeed.notches(0) - 6) < 0.001)
        #expect(abs(WheelSpeed.notches(1) - 1) < 0.001)
        // Every part of the slider changes it.
        let steps = stride(from: 0.0, through: 1.0, by: 0.1).map(WheelSpeed.notches)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test func fasterFlipsSooner() {
        #expect(WheelSpeed.interval(0) > WheelSpeed.interval(0.5))
        #expect(WheelSpeed.interval(0.5) > WheelSpeed.interval(1))
    }
}
