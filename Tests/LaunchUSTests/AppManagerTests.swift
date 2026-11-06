import Foundation
import Testing
@testable import LaunchUS

struct UpdateCheckerTests {
    @Test func comparesVersionsByNumber() {
        #expect(UpdateChecker.compare("1.10", "1.9") == .orderedDescending)
        #expect(UpdateChecker.compare("2.0", "2") == .orderedSame)
        #expect(UpdateChecker.compare("3.2.1", "3.10") == .orderedAscending)
        #expect(UpdateChecker.compare("1500", "1499") == .orderedDescending)
    }

    @Test func picksTheNewestUsableRelease() throws {
        let appcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>2.1</title>
              <sparkle:version>210</sparkle:version>
              <sparkle:shortVersionString>2.1</sparkle:shortVersionString>
              <enclosure url="https://example.com/a.zip" length="1" type="application/octet-stream"/>
            </item>
            <item>
              <title>2.3 beta</title>
              <sparkle:channel>beta</sparkle:channel>
              <enclosure url="https://example.com/b.zip" sparkle:version="230" sparkle:shortVersionString="2.3b1"/>
            </item>
            <item>
              <title>2.2</title>
              <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.com/c.zip" sparkle:version="220" sparkle:shortVersionString="2.2"/>
            </item>
            <item>
              <title>9.0 for a future macOS</title>
              <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.com/d.zip" sparkle:version="900" sparkle:shortVersionString="9.0"/>
            </item>
          </channel>
        </rss>
        """
        let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let latest = try #require(UpdateChecker.latest(inAppcast: Data(appcast.utf8), system: system))
        #expect(latest.build == "220")
        #expect(latest.short == "2.2")
    }

    @Test func rejectsWhatIsNotAnAppcast() {
        #expect(UpdateChecker.latest(inAppcast: Data("not xml <".utf8)) == nil)
        #expect(UpdateChecker.latest(inAppcast: Data("<rss><channel></channel></rss>".utf8)) == nil)
    }
}

struct LaunchLogTests {
    private let calendar = Calendar.current
    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
    }

    @Test func countsByDayAndDropsOldDays() {
        var log: [String: [String: Int]] = ["2026-08-01": ["old": 3]]
        log = LaunchLog.adding("a", at: date(5), to: log)
        log = LaunchLog.adding("a", at: date(5), to: log)
        log = LaunchLog.adding("b", at: date(6), to: log)
        #expect(log["2026-11-05"] == ["a": 2])
        #expect(log["2026-11-06"] == ["b": 1])
        #expect(log["2026-08-01"] == nil)
    }

    @Test func topAndPerDay() {
        let log = ["2026-11-06": ["a": 1, "b": 4], "2026-11-04": ["a": 5], "2026-10-20": ["c": 50]]
        let top = LaunchLog.top(log, days: 7, now: date(6))
        #expect(top.map(\.id) == ["a", "b"])
        #expect(top.map(\.count) == [6, 4])
        let days = LaunchLog.perDay(log, days: 3, now: date(6))
        #expect(days.map(\.count) == [5, 0, 5])
        #expect(calendar.isDate(days.last!.date, inSameDayAs: date(6)))
    }
}
