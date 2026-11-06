import Testing
@testable import LaunchUS

@MainActor
struct DockMenuTests {
    @Test func appsAreFiledUnderTheirFirstLetter() {
        #expect(AppDelegate.indexLetter(for: app("Safari")) == "S")
        #expect(AppDelegate.indexLetter(for: app("微信")) == "W")
        #expect(AppDelegate.indexLetter(for: app("éclair")) == "E")
        #expect(AppDelegate.indexLetter(for: app("1Password")) == "#")
    }
}
