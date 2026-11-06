import Testing
@testable import LaunchUS

@Suite struct UninstallerMatchTests {
    let id = "com.example.app"

    @Test(arguments: [
        "com.example.app",
        "com.example.app.plist",
        "com.example.app.helper",
        "com.example.app.savedstate",
        "com.example.app.binarycookies",
        "com.example.app.0a1b2c3d-1111-2222-3333-444455556666.plist",
        "group.com.example.app",
        "abcde12345.com.example.app",
        "abcde12345.com.example.app.shared",
    ])
    func matches(_ name: String) {
        #expect(Uninstaller.matches(name, bundleID: id, appName: nil))
    }

    @Test(arguments: [
        "com.example.apple",
        "com.example",
        "com.example.app2.plist",
        "group.com.example.apps",
        "abc.com.example.app",
        "example",
    ])
    func doesNotMatch(_ name: String) {
        #expect(!Uninstaller.matches(name, bundleID: id, appName: nil))
    }

    @Test func appNameOnlyWhereAllowedAndLongEnough() {
        #expect(Uninstaller.matches("example", bundleID: id, appName: "example"))
        #expect(!Uninstaller.matches("ex", bundleID: id, appName: "ex"))
    }
}
