import Foundation
import Testing
@testable import LaunchUS

struct HotCornerTests {
    // Two displays side by side, the right one shorter and aligned to the bottom.
    let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let right = CGRect(x: 1000, y: 0, width: 800, height: 600)

    @Test func cornersTouchingAnotherDisplayDontCount() {
        let screens = [left, right]
        #expect(HotCornerWatcher.isOuterCorner(.topLeft, of: left, among: screens))
        #expect(HotCornerWatcher.isOuterCorner(.topRight, of: left, among: screens))  // above the shorter display
        #expect(!HotCornerWatcher.isOuterCorner(.bottomRight, of: left, among: screens))
        #expect(!HotCornerWatcher.isOuterCorner(.bottomLeft, of: right, among: screens))
        #expect(!HotCornerWatcher.isOuterCorner(.topLeft, of: right, among: screens))  // left display goes higher
        #expect(HotCornerWatcher.isOuterCorner(.topRight, of: right, among: screens))
        #expect(HotCornerWatcher.isOuterCorner(.bottomRight, of: left, among: [left]))
    }

    @Test func systemCornerWithoutModifierIsAConflict() throws {
        let defaults = try #require(UserDefaults(suiteName: "LaunchUSTests.hotCorners"))
        defer { defaults.removePersistentDomain(forName: "LaunchUSTests.hotCorners") }
        defaults.set(4, forKey: "wvous-tr-corner")      // Desktop
        defaults.set(1, forKey: "wvous-tl-corner")      // no action
        defaults.set(2, forKey: "wvous-br-corner")
        defaults.set(1 << 20, forKey: "wvous-br-modifier") // only with ⌘
        #expect(SystemHotCorners.isTaken(.topRight, defaults: defaults))
        #expect(!SystemHotCorners.isTaken(.topLeft, defaults: defaults))
        #expect(!SystemHotCorners.isTaken(.bottomRight, defaults: defaults))
        #expect(!SystemHotCorners.isTaken(.off, defaults: defaults))
    }
}
