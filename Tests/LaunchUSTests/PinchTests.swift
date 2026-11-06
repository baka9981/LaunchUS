import Testing
@testable import LaunchUS

struct PinchTests {
    @Test func spreadIsMeanDistanceFromCentre() {
        let square: [(Float, Float)] = [(0, 0), (0.2, 0), (0, 0.2), (0.2, 0.2)]
        #expect(abs(TrackpadPinch.spread(square) - 0.1414) < 0.001)
        let closer = square.map { ($0.0 * 0.5, $0.1 * 0.5) }
        #expect(TrackpadPinch.spread(closer) < TrackpadPinch.spread(square) * TrackpadPinch.inThreshold)
    }

    @Test func progressFollowsTheFingersAndStopsAtTheThreshold() {
        #expect(TrackpadPinch.progress(.pinchIn, ratio: 1) == 0)
        #expect(abs(TrackpadPinch.progress(.pinchIn, ratio: 0.875) - 0.5) < 0.001)
        #expect(TrackpadPinch.progress(.pinchIn, ratio: 0.5) == 1)
        #expect(TrackpadPinch.progress(.pinchIn, ratio: 1.2) == 0)
        #expect(TrackpadPinch.progress(.spread, ratio: TrackpadPinch.outThreshold) == 1)
        #expect(TrackpadPinch.progress(.spread, ratio: 0.9) == 0)
    }

    @Test func fourOrFiveAcceptsBothCounts() {
        #expect(TrackpadPinch.fingerCounts(for: TrackpadPinch.fourOrFive) == [4, 5])
        #expect(TrackpadPinch.fingerCounts(for: 3) == [3])
        #expect(TrackpadPinch.fingerCounts(for: 9) == [5])
    }
}
