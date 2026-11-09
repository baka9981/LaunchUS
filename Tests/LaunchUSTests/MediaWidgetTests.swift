import Foundation
import Testing
@testable import LaunchUS

@MainActor
struct CalculatorWidgetTests {
    private func run(_ keys: [String]) -> String {
        let calc = Calculators.shared
        let id = UUID().uuidString
        defer { calc.forget(id) }
        for key in keys { calc.press(key, id) }
        return calc.state(id).entry
    }

    @Test func chainsLikeAPocketCalculator() {
        #expect(run(["1", "2", "+", "3", "="]) == "15")
        #expect(run(["2", "+", "3", "×", "4", "="]) == "20")
        #expect(run(["7", "÷", "2", "="]) == "3.5")
        #expect(run(["0", ".", "1", "+", "0", ".", "2", "="]) == "0.3")
    }

    @Test func percentOfTheStoredValueWhenAdding() {
        #expect(run(["2", "0", "0", "+", "1", "0", "%", "="]) == "220")
        #expect(run(["5", "0", "%"]) == "0.5")
    }

    @Test func divideByZeroShowsAnErrorThatBackspaceClears() {
        #expect(run(["1", "÷", "0", "="]) == Calculators.format(.nan))
        #expect(run(["1", "÷", "0", "=", "⌫"]) == "0")
        #expect(run(["1", "2", "⌫", "⌫"]) == "0")
        #expect(run(["4", "±"]) == "-4")
    }
}

@MainActor
struct UsageLogTests {
    @Test func addsUpPerDayAndDropsOldDays() {
        let now = Date()
        var log = AppUsage.adding(30, to: "a", at: now, in: [:])
        log = AppUsage.adding(15, to: "a", at: now, in: log)
        #expect(log[LaunchLog.day(now)]?["a"] == 45)
        for back in 1...(AppUsage.keepDays + 5) {
            let day = Calendar.current.date(byAdding: .day, value: -back, to: now)!
            log[LaunchLog.day(day)] = ["b": 1]
        }
        log = AppUsage.adding(1, to: "a", at: now, in: log)
        #expect(log.count <= AppUsage.keepDays)
        #expect(log[LaunchLog.day(now)]?["a"] == 46)
    }
}
