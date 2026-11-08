import CoreGraphics
import Testing
@testable import LaunchUS

@Suite struct ClickBurstTests {
    /// Which of the clicks (time, x) complete a burst.
    private func bursts(_ count: Int, _ clicks: [(Double, CGFloat)]) -> [Bool] {
        var b = ClickBurst(count: count)
        return clicks.map { b.click(at: $0.0, CGPoint(x: $0.1, y: 0)) }
    }

    @Test func quickClicksInOnePlaceMakeABurst() {
        // The fourth click starts the next burst.
        #expect(bursts(3, [(0, 0), (0.2, 3), (0.4, 5), (0.5, 0)]) == [false, false, true, false])
    }

    @Test func aPauseOrAMoveStartsOver() {
        #expect(bursts(2, [(0, 0), (1, 0), (1.3, 0)]) == [false, false, true])
        #expect(bursts(2, [(0, 0), (0.1, 100), (0.2, 104)]) == [false, false, true])
    }

    @Test func buttonTitles() {
        #expect(MouseButton.title(MouseButton.off) == "未设置")
        #expect(MouseButton.title(2) == "中键")
        #expect(MouseButton.title(3) == "侧键 1")
    }
}
