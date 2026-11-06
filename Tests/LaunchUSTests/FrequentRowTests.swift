import Testing
@testable import LaunchUS

struct FrequentRowTests {
    let apps = ["a", "b", "c", "d"].map { app($0) }

    @Test func pinnedComeFirstAndRemovedStayOff() {
        let row = RecentLaunches.row(apps: apps, recent: ["b", "c", "a"], pinned: ["d"], removed: ["c"],
                                     limit: 3, ownID: nil)
        #expect(row.map(\.id) == ["d", "b", "a"])
    }

    @Test func pinnedAppIsNotListedTwice() {
        let row = RecentLaunches.row(apps: apps, recent: ["a", "b"], pinned: ["b"], removed: [], limit: 5, ownID: nil)
        #expect(row.map(\.id) == ["b", "a"])
    }
}
