import AppKit
import Testing
@testable import LaunchUS

struct AppInfoTests {
    @Test func tellsTheChip() {
        #expect(AppInfo.architecture([NSBundleExecutableArchitectureARM64]) == .appleSilicon)
        #expect(AppInfo.architecture([NSBundleExecutableArchitectureX86_64]) == .intel)
        #expect(AppInfo.architecture([NSBundleExecutableArchitectureX86_64, NSBundleExecutableArchitectureARM64]) == .universal)
        #expect(AppInfo.architecture([]) == nil)
    }

    @Test func readsABundle() {
        let info = AppInfo.read(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        #expect(info.version != nil)
        #expect(info.architecture != nil)
        #expect(!info.fromAppStore)
    }
}
