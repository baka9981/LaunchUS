import Foundation
import Testing
@testable import LaunchUS

@MainActor
struct UsageReportTests {
    @Test func viaListsOnlyUsedSourcesInOrder() {
        #expect(Heartbeat.viaParameter(["pinch": 5, "hotKey": 3, "f4": 0]) == "hotKey:3,pinch:5")
        #expect(Heartbeat.viaParameter([:]) == "")
    }

    @Test func crashReportParses() throws {
        let header = #"{"app_name":"LaunchUS","app_version":"1.4.1","os_version":"macOS 26.1 (25B78)","incident_id":"X"}"#
        let body = #"""
        {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
         "asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},
         "faultingThread":0,
         "usedImages":[{"name":"LaunchUS","path":"/Users/someone/LaunchUS.app"},{"name":"libswiftCore.dylib"}],
         "threads":[{"frames":[{"imageIndex":1,"symbol":"_assertionFailure"},{"imageIndex":0,"imageOffset":4096}]}]}
        """#
        let report = try #require(CrashReports.parse(header + "\n" + body))
        #expect(report.version == "1.4.1")
        #expect(report.os == "26.1")
        #expect(report.type == "EXC_BREAKPOINT")
        #expect(report.signal == "SIGTRAP")
        #expect(report.reason == "Fatal error: Index out of range")
        #expect(report.frames == ["libswiftCore.dylib _assertionFailure", "LaunchUS 0x1000"])
        let url = try #require(CrashReports.url(for: report, base: URL(string: "https://dl.example.com/")!))
        #expect(url.path == "/crash")
        #expect(!url.absoluteString.contains("Users"))
    }

    @Test func otherAppsReportsAreIgnored() {
        #expect(CrashReports.parse(#"{"app_name":"Finder"}"# + "\n{}") == nil)
    }
}
