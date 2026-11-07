import AppKit
import Foundation
import Testing
@testable import LaunchUS

@Suite struct LaunchItemTests {
    @Test func profileLinks() {
        #expect(URLCommand(url: URL(string: "launchus://profile?name=%E5%B7%A5%E4%BD%9C")!) == .profile("工作"))
        #expect(URLCommand(url: URL(string: "launchus://layout?name=Home")!) == .profile("Home"))
        #expect(URLCommand(url: URL(string: "launchus://profile")!) == nil)
    }

    @Test func profileNames() {
        var file = LayoutProfiles.File()
        file.saved = ["工作": [], "Games": [], "": []]
        let names = LayoutProfiles.names(file)
        #expect(names.first == "")
        #expect(Set(names) == ["", "Games", "工作"])
        #expect(LayoutProfiles.resolve("games", in: file) == "Games")
        #expect(LayoutProfiles.resolve(" 工作 ", in: file) == "工作")
        #expect(LayoutProfiles.resolve("默认", in: file) == "")
        #expect(LayoutProfiles.resolve("Default", in: file) == "")
        #expect(LayoutProfiles.resolve("娱乐", in: file) == nil)
    }

    @Test func webAddresses() {
        #expect(CustomItem(kind: .url, name: "A", target: "example.com").webURL?.absoluteString == "https://example.com")
        #expect(CustomItem(kind: .url, name: "A", target: "http://x.org/a").webURL?.absoluteString == "http://x.org/a")
        #expect(CustomItem(kind: .url, name: "A", target: "obsidian://open").webURL?.scheme == "obsidian")
        #expect(CustomItem(kind: .file, name: "A", target: "x.com").webURL == nil)
    }

    @Test func itemsBecomeApps() {
        let file = CustomItem(kind: .file, name: "下载", target: "~/Downloads")
        let app = file.appItem
        #expect(app.id.hasPrefix(CustomItem.idPrefix))
        #expect(CustomItem.isCustom(app.id))
        #expect(app.isCustom)
        #expect(app.url.path == NSString(string: "~/Downloads").expandingTildeInPath)
        #expect(app.iconPath == app.url.path)
        #expect(app.searchNames.contains("~/downloads"))

        let script = CustomItem(kind: .script, name: "Build", target: "make").appItem
        #expect(script.iconPath == IconRenderer.symbolPrefix + "terminal.fill")
        #expect(CustomItem(kind: .url, name: "Web", target: "a.com").appItem.iconPath == IconRenderer.symbolPrefix + "globe")
    }

    @Test func itemsRoundTrip() throws {
        let items = [CustomItem(kind: .script, name: "S", target: "echo \"hi\"")]
        let decoded = try JSONDecoder().decode([CustomItem].self, from: JSONEncoder().encode(items))
        #expect(decoded == items)
    }

    @Test func metaIcon() throws {
        let old = try JSONDecoder().decode(AppMeta.self, from: Data(#"{"tags":["a"]}"#.utf8))
        #expect(old.icon == nil)
        var meta = AppMeta()
        meta.icon = "symbol:star.fill"
        let decoded = try JSONDecoder().decode(AppMeta.self, from: JSONEncoder().encode(meta))
        #expect(decoded.icon == "symbol:star.fill")
        #expect(CustomIcons.path(for: "symbol:star.fill") == "symbol:star.fill")
        #expect(CustomIcons.path(for: "a.png").hasSuffix("/Icons/a.png"))
    }

    @Test func badgeSums() {
        #expect(DockBadges.sum([]) == nil)
        #expect(DockBadges.sum(["3", "12"]) == "15")
        #expect(DockBadges.sum(["3", "•"]) == "•")
        #expect(DockBadges.sum(["999", "5"]) == "999+")
    }

    @Test func frequentRowMetrics() {
        let size = CGSize(width: 1_512, height: 982)
        let plain = GridMetrics(size: size, columns: 7, rows: 5, paged: false)
        let withRow = GridMetrics(size: size, columns: 7, rows: 5, paged: false, frequentRow: true)
        // A full grid row plus a line, scrolling with the grid: the grid's rows and top don't change.
        #expect(withRow.cellSize == plain.cellSize)
        #expect(withRow.gridTop == plain.gridTop)
        // As in the system Apps window: under the line is the usual gap between rows, and the line
        // sits about four fifths of that under the names.
        let m = withRow
        let above = m.frequentLineY - m.frequentLabelBottom
        let below = m.frequentHeight + m.cellSize.height / 2 - m.iconSize * 0.4 - (m.frequentLineY + 1)
        #expect(abs(below - m.rowGap) <= 1)
        #expect(abs(above / below - 0.79) < 0.06)
        #expect(plain.frequentHeight == 0)
    }

    @Test func syncPayloadNamesProfile() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = #"{"app":"LaunchUS","version":1,"device":"A","deviceID":"x","modified":"2026-01-01T00:00:00Z","pages":[],"meta":{}}"#
        #expect(try decoder.decode(ICloudSync.Payload.self, from: Data(old.utf8)).profile == nil)
        let new = #"{"app":"LaunchUS","version":1,"device":"A","deviceID":"x","modified":"2026-01-01T00:00:00Z","pages":[],"meta":{},"profile":"工作"}"#
        #expect(try decoder.decode(ICloudSync.Payload.self, from: Data(new.utf8)).profile == "工作")
    }

    @Test func borrowedAppIconIsRealIcns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = try CustomIcons.importAppIcon(URL(fileURLWithPath: "/System/Applications/Calculator.app"), into: dir)
        let path = dir.appendingPathComponent(name).path
        #expect(name.hasSuffix(".icns"))
        #expect(NSImage(contentsOfFile: path) != nil)
    }

    @Test @MainActor func launchItemsJoinCatalogWithoutRescan() {
        let app = CustomItem(kind: .url, name: "Beta", target: "b.example").appItem
        let catalog = AppCatalog(apps: [app], scan: { [] }, renderIcon: { _ in nil }, folderPaths: { [] })
        var changes = 0
        catalog.onChange = { changes += 1 }
        let item = CustomItem(kind: .url, name: "Alpha", target: "a.example").appItem
        catalog.customApps = [item]
        #expect(catalog.apps.map(\.name) == ["Alpha", "Beta"])
        #expect(changes == 1)
        catalog.customApps = [item]
        #expect(changes == 1)
        catalog.customApps = []
        #expect(catalog.apps.map(\.name) == ["Beta"])
    }

    @Test func backupCarriesOtherProfiles() throws {
        let file = LayoutProfiles.File(current: "工作", saved: ["": [], "工作": [], "娱乐": []])
        let backup = LayoutBackup(pages: [], meta: [:], custom: [], profiles: file)
        let decoded = try JSONDecoder().decode(LayoutBackup.self, from: JSONEncoder().encode(backup))
        #expect(decoded.profile == "工作")
        #expect(Set(decoded.profiles?.keys ?? [:].keys) == ["", "娱乐"])
    }
}

