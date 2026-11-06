import Foundation
import Testing
@testable import LaunchUS

struct AliasAppTests {
    @Test func aliasesAndLinksToAppsResolveToTheApp() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("LaunchUSAlias-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Real/Thing.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)

        // A Finder alias without the .app extension.
        let alias = dir.appendingPathComponent("Thing alias")
        let bookmark = try app.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        #expect(AppScanner.appURL(alias)?.standardizedFileURL.path == app.resolvingSymlinksInPath().standardizedFileURL.path)

        // A symbolic link without the extension.
        let link = dir.appendingPathComponent("Thing link")
        try fm.createSymbolicLink(at: link, withDestinationURL: app)
        #expect(AppScanner.appURL(link)?.lastPathComponent == "Thing.app")

        // Anything else is ignored.
        let text = dir.appendingPathComponent("notes.txt")
        try Data().write(to: text)
        #expect(AppScanner.appURL(text) == nil)
    }
}
