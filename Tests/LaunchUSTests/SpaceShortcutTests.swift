import Foundation
import Testing
@testable import LaunchUS

struct SpaceShortcutTests {
    private func used(_ name: String, count: Int, daysAgo: Double, now: Date) -> AppItem {
        var item = app(name)
        item.useCount = count
        item.lastUsedDate = now.addingTimeInterval(-daysAgo * 86_400)
        return item
    }

    @Test func spaceAndArrowsGoRound() {
        #expect(SpaceShortcut.guess.step(1) == .recent)
        #expect(SpaceShortcut.recent.step(1) == .mostUsed)
        #expect(SpaceShortcut.mostUsed.step(1) == .guess)
        #expect(SpaceShortcut.guess.step(-1) == .mostUsed)
    }

    @Test func recentAndMostUsed() {
        let now = Date()
        let apps = [used("Old", count: 50, daysAgo: 30, now: now), used("New", count: 2, daysAgo: 0.1, now: now),
                    used("Mid", count: 10, daysAgo: 3, now: now), app("Never")]
        #expect(SpaceShortcut.recent.apps(from: apps, recent: [], hours: [:], now: now, ownID: nil).map(\.name) == ["New", "Mid", "Old"])
        #expect(SpaceShortcut.mostUsed.apps(from: apps, recent: [], hours: [:], now: now, ownID: nil).map(\.name) == ["Old", "Mid", "New"])
        // Opened through LaunchUS counts as most recent.
        let oldID = apps[0].id
        #expect(SpaceShortcut.recent.apps(from: apps, recent: [oldID], hours: [:], now: now, ownID: nil).first?.name == "Old")
    }

    @Test func guessFavoursThisHour() throws {
        let now = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()))
        let apps = [used("Busy", count: 40, daysAgo: 1, now: now), used("Morning", count: 3, daysAgo: 1, now: now), app("Never")]
        var morning = Array(repeating: 0, count: 24)
        morning[9] = 8
        let guess = SpaceShortcut.guess.apps(from: apps, recent: [], hours: [apps[1].id: morning], now: now, ownID: nil)
        #expect(guess.map(\.name) == ["Morning", "Busy"])
    }

    @Test func hourCountsFade() {
        var counts: [Int]? = nil
        for _ in 0..<61 { counts = LaunchHours.adding(9, to: counts) }
        #expect(counts!.count == 24)
        #expect(counts![9] == 30)
    }
}
