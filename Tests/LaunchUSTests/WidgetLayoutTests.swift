import Foundation
import Testing
@testable import LaunchUS

@Suite struct WidgetLayoutTests {
    let clock = WidgetItem(id: "w", kind: BuiltInWidget.clock.rawValue, size: .small)
    let wide = WidgetItem(id: "m", kind: BuiltInWidget.system.rawValue, size: .medium)

    /// Apps around a 2×2 widget on a 4-column page: covers fill its cells, so index == cell.
    @Test func packPlacesWidgetAndCovers() {
        let items: [LayoutItem] = [.widget(clock)] + ["a", "b", "c", "d", "e"].map(LayoutItem.app)
        let (page, overflow) = LayoutOps.pack(items, columns: 4, rows: 3, free: false)
        #expect(overflow.isEmpty)
        #expect(page == [.widget(clock), .cover("w"), .app("a"), .app("b"),
                         .cover("w"), .cover("w"), .app("c"), .app("d"),
                         .app("e")])
    }

    /// A widget that doesn't fit after the apps in front of it goes to the first block it fits,
    /// and the cells it skipped are filled by the apps after it.
    @Test func packWidgetSkipsToFittingBlock() {
        let items: [LayoutItem] = [.app("a"), .app("b"), .app("c"), .widget(clock), .app("d")]
        let (page, _) = LayoutOps.pack(items, columns: 4, rows: 3, free: false)
        #expect(page == [.app("a"), .app("b"), .app("c"), .app("d"),
                         .widget(clock), .cover("w"), .cover(""), .cover(""),
                         .cover("w"), .cover("w")])
    }

    @Test func packOverflowsWhatDoesntFit() {
        let items: [LayoutItem] = ["a", "b", "c", "d", "e"].map(LayoutItem.app) + [.widget(wide), .app("f")]
        let (page, overflow) = LayoutOps.pack(items, columns: 4, rows: 2, free: false)
        #expect(page == ["a", "b", "c", "d", "e"].map(LayoutItem.app))
        #expect(overflow == [.widget(wide), .app("f")])
    }

    @Test func repackIsIdempotent() {
        let pages: [[LayoutItem]] = [[.app("a"), .widget(wide)] + (1...12).map { .app("x\($0)") }, [.widget(clock), .app("z")]]
        for free in [false, true] {
            let once = LayoutOps.repack(pages, perPage: 12, columns: 4, free: free)
            let twice = LayoutOps.repack(once, perPage: 12, columns: 4, free: free)
            #expect(once == twice)
            for page in once { #expect(page.count <= 12) }
            // Every app and widget is still there exactly once.
            let ids = once.joined().filter { !$0.isGap }.map(\.id)
            #expect(Set(ids).count == ids.count)
            #expect(ids.count == 16)
        }
    }

    /// Widgets pushing apps on to later pages, then going again: the apps come back, so pages
    /// aren't left half empty (what scrolling, which only adds to the first page, piled up).
    @Test func removingWidgetsTakesBackPushedApps() {
        let original = LayoutOps.repack([(1...40).map { .app("a\($0)") }], perPage: 35, columns: 7)
        var layout = original
        let widgets = (1...6).map { WidgetItem(id: "w\($0)", kind: "k", size: $0 % 2 == 0 ? .small : .medium) }
        for w in widgets {
            layout[0].insert(.widget(w), at: 0)
            layout = LayoutOps.repack(layout, perPage: 35, columns: 7)
        }
        #expect(layout.count == 3)
        for w in widgets {
            let wasFull = LayoutOps.fullPages(layout, columns: 7, rows: 5)
            let p = layout.firstIndex { $0.contains(.widget(w)) }!
            layout[p][layout[p].firstIndex(of: .widget(w))!] = .cover("")
            layout = LayoutOps.refill(layout, wasFull: wasFull, columns: 7, rows: 5)
        }
        #expect(layout == original)
    }

    /// A page the user ended early keeps its break; only full pages take apps back.
    @Test func refillKeepsPagesEndedByHand() {
        let pages: [[LayoutItem]] = [[.widget(clock)] + (1...8).map { .app("a\($0)") }, [.app("b1"), .app("b2")], [.app("c1")]]
        let wasFull = LayoutOps.fullPages(pages, columns: 4, rows: 3)
        #expect(wasFull == [true, false, false])
        var removed = LayoutOps.repack(pages, perPage: 12, columns: 4)
        removed[0][0] = .cover("")
        let result = LayoutOps.refill(removed, wasFull: wasFull, columns: 4, rows: 3)
        #expect(result == [(1...8).map { .app("a\($0)") } + [.app("b1"), .app("b2")], [.app("c1")]])
    }

    /// A widget made smaller frees cells the pushed apps come back to.
    @Test func shrinkingWidgetTakesBackPushedApps() {
        let big = WidgetItem(id: "L", kind: "k", size: .large)
        let pages = LayoutOps.repack([[.widget(big)] + (1...12).map { .app("a\($0)") }], perPage: 24, columns: 6)
        #expect(pages.count == 2)
        let wasFull = LayoutOps.fullPages(pages, columns: 6, rows: 4)
        var shrunk = pages
        shrunk[0][0] = .widget(WidgetItem(id: "L", kind: "k", size: .small))
        let result = LayoutOps.refill(shrunk, wasFull: wasFull, columns: 6, rows: 4)
        #expect(result.count == 1)
        #expect(result[0].filter { !$0.isGap }.count == 13)
    }

    @Test func removingWidgetClosesItsCellsWhenLinedUp() {
        let page = LayoutOps.pack([.widget(clock), .app("a"), .app("b"), .app("c")], columns: 4, rows: 3, free: false).page
        var removed = page
        removed[0] = .cover("")
        let result = LayoutOps.repack([removed], perPage: 12, columns: 4)
        #expect(result == [[.app("a"), .app("b"), .app("c")]])
    }

    @Test func removingWidgetLeavesEmptyCellsInFreePlacement() {
        let page = LayoutOps.pack([.widget(clock), .app("a"), .app("b"), .app("c")], columns: 4, rows: 3, free: true).page
        var removed = page
        removed[0] = .gap
        let result = LayoutOps.repack([removed], perPage: 12, columns: 4, free: true)
        // "c" stays in the second row, third column.
        #expect(result.first?.firstIndex(of: .app("c")) == 6)
    }

    @Test func reconcileKeepsWidgetsAndDropsDuplicates() {
        let installed = ["a", "b"].map { app($0) }
        let result = LayoutOps.reconcile([[.widget(clock), .app("a")], [.widget(clock)]], installed: installed,
                                         hidden: [], perPage: 12, columns: 4)
        #expect(result.joined().filter(\.isWidget).count == 1)
        #expect(result.joined().contains(.app("b")))
    }

    /// Older versions read a widget as an empty cell and covers as gaps.
    @Test func encodingStaysReadableAndRoundTrips() throws {
        let page: [LayoutItem] = [.widget(clock), .cover("w"), .app("a")]
        let data = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode([LayoutItem].self, from: data)
        #expect(decoded[0] == .widget(clock))
        #expect(decoded[1].isGap)
        #expect(decoded[2] == .app("a"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect((json[0]["app"] as? [String: String])?["_0"] == "")
    }

    @Test func legacyKindAndUnknownSize() throws {
        let old = try JSONDecoder().decode(WidgetItem.self, from: Data(#"{"id":"x","kind":"clock","size":"huge"}"#.utf8))
        #expect(old.kind == BuiltInWidget.clock.rawValue && old.size == .small)
        // A plugin's ID stays as it is, installed or not.
        let plugin = try JSONDecoder().decode(WidgetItem.self, from: Data(#"{"id":"y","kind":"com.example.weather","size":"medium"}"#.utf8))
        #expect(plugin.kind == "com.example.weather" && plugin.size == .medium)
    }

    @Test func spanClampsToGrid() {
        #expect(WidgetItem.Size.large.span(columns: 3, rows: 2) == (3, 2))
        #expect(WidgetItem.Size.medium.span(columns: 7, rows: 5) == (4, 2))
    }

    /// Free placement: a widget dropped in the last row moves up into empty cells instead of
    /// taking the rest of the page to the next one.
    @Test func freeWidgetPastBottomMovesUpIntoEmptyCells() {
        let empty = Array(repeating: LayoutItem.gap, count: 6)
        let items: [LayoutItem] = [.app("a")] + empty + [.app("b")] + empty
            + (1...7).map { .app("r\($0)") } + [.app("x"), .widget(clock), .app("y")]
        let (page, overflow) = LayoutOps.pack(items, columns: 7, rows: 4, free: true)
        #expect(overflow.isEmpty)
        #expect(page.firstIndex(of: .widget(clock)) == 1)
        #expect(page.firstIndex(of: .app("x")) == 21)
        #expect(page.firstIndex(of: .app("y")) == 22)
        let again = LayoutOps.pack(page, columns: 7, rows: 4, free: true)
        #expect(again.page == page && again.overflow.isEmpty)
    }

    @Test func freeWidgetWithNoRoomGoesOnAlone() {
        let items: [LayoutItem] = (1...14).map { .app("r\($0)") } + [.app("x"), .widget(clock), .app("y")]
        let (page, overflow) = LayoutOps.pack(items, columns: 7, rows: 3, free: true)
        #expect(overflow == [.widget(clock)])
        #expect(page.contains(.app("y")))
    }

    @Test func loneWidgetOverflowKeepsEmptyCells() {
        let empty = Array(repeating: LayoutItem.gap, count: 5)
        let page: [LayoutItem] = [.app("a")] + empty + [.app("b")] + (1...7).map { .app("r\($0)") } + [.widget(clock)]
        let result = LayoutOps.repack([page], perPage: 21, columns: 7, free: true)
        #expect(result.first?.firstIndex(of: .app("b")) == 6)
        #expect(result.count == 2 && result[1].first == .widget(clock))
    }
}
