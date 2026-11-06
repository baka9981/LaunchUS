import CoreGraphics
import Foundation
import Testing
@testable import LaunchUS

struct OrganizeTests {
    let pages: [[LayoutItem]] = [
        [.app("a"), .folder(Folder(id: "f1", name: "F1", apps: ["b", "c"])), .app("d")],
        [.folder(Folder(id: "s", name: "Smart", apps: [], query: "#x")), .app("e")],
    ]

    @Test func ungroupingLeavesAppsWhereTheFolderWas() {
        let result = LayoutOps.ungrouped(pages, perPage: 4)
        #expect(result.joined().map(\.id) == ["app:a", "app:b", "app:c", "app:d", "folder:s", "app:e"])
        #expect(result.map(\.count) == [4, 2])
    }

    @Test func foldersGatherAtEitherEnd() {
        let first = LayoutOps.foldersMoved(pages, toStart: true, perPage: 10).joined().map(\.id)
        #expect(first == ["folder:f1", "folder:s", "app:a", "app:d", "app:e"])
        let last = LayoutOps.foldersMoved(pages, toStart: false, perPage: 10).joined().map(\.id)
        #expect(last == ["app:a", "app:d", "app:e", "folder:f1", "folder:s"])
    }

    @Test func arrangeByLastOpenedPutsTheRecentFirst() {
        var old = app("Old"), recent = app("Recent"), never = app("Never")
        old.lastUsedDate = Date(timeIntervalSince1970: 1000)
        recent.lastUsedDate = Date(timeIntervalSince1970: 5000)
        var rules = LayoutRules()
        rules.groupByCategory = false
        rules.systemAppsFolder = false
        rules.order = .lastOpened
        let result = LayoutOps.arranged([old, never, recent], current: [], hidden: [], rules: rules, perPage: 10)
        #expect(result.joined().map(\.id) == ["app:Recent", "app:Old", "app:Never"])
    }

    @Test func arrangeByColourFollowsTheHueThenGreys() {
        let colors: [String: IconColor] = [
            "Blue": IconColor(hue: 0.6, saturation: 0.8, brightness: 0.9),
            "Red": IconColor(hue: 0.99, saturation: 0.9, brightness: 0.9),
            "Green": IconColor(hue: 0.33, saturation: 0.7, brightness: 0.8),
            "Grey": IconColor(hue: 0, saturation: 0.05, brightness: 0.6),
        ]
        var rules = LayoutRules()
        rules.groupByCategory = false
        rules.systemAppsFolder = false
        rules.order = .color
        let apps = ["Grey", "Blue", "Green", "Red"].map { app($0) }
        let result = LayoutOps.arranged(apps, current: [], hidden: [], rules: rules, perPage: 10, colors: colors)
        #expect(result.joined().map(\.id) == ["app:Red", "app:Green", "app:Blue", "app:Grey"])
    }

    @Test func iconColourReadsTheMainHue() throws {
        let side = 32
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 4, y: 4, width: 24, height: 24))
        let image = try #require(ctx.makeImage())
        let color = try #require(IconColor.of(image))
        #expect(abs(color.hue - 0.6) < 0.05)
        #expect(color.saturation > 0.5)
    }
}
