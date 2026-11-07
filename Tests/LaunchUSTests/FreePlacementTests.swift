import Foundation
import Testing
@testable import LaunchUS

/// Free placement: icons stay in their cell and empty cells are kept.
@Suite struct FreePlacementTests {
    private let a = LayoutItem.app("a"), b = LayoutItem.app("b"), c = LayoutItem.app("c"), d = LayoutItem.app("d")

    @Test func gapsSurviveEncoding() throws {
        let pages: [[LayoutItem]] = [[a, .gap, b], [.gap, .folder(Folder(id: "f", name: "F", apps: ["c"]))]]
        let data = try JSONEncoder().encode(pages)
        #expect(try JSONDecoder().decode([[LayoutItem]].self, from: data) == pages)
    }

    @Test func storedInTheOldShape() throws {
        // Layouts saved before empty cells existed still load, and a gap reads to them as an app with no ID.
        let old = #"[[{"app":{"_0":"a"}},{"folder":{"_0":{"id":"f","name":"F","apps":["b"]}}}]]"#
        let pages = try JSONDecoder().decode([[LayoutItem]].self, from: Data(old.utf8))
        #expect(pages.first?.first == a)
        let gap = String(decoding: try JSONEncoder().encode(LayoutItem.gap), as: UTF8.self)
        #expect(gap == #"{"app":{"_0":""}}"#)
    }

    @Test func linedUpRepackClosesGaps() {
        #expect(LayoutOps.repack([[a, .gap, b, .gap]], perPage: 4) == [[a, b]])
    }

    @Test func freeRepackKeepsGapsButTrimsTheEnd() {
        #expect(LayoutOps.repack([[a, .gap, b, .gap, .gap], [.gap, .gap]], perPage: 6, free: true) == [[a, .gap, b]])
    }

    @Test func freeRepackGivesUpGapsBeforePushingIcons() {
        // Five items in a four-cell page: the empty cell goes, nothing moves on.
        #expect(LayoutOps.repack([[a, .gap, b, c, d]], perPage: 4, free: true) == [[a, b, c, d]])
        #expect(LayoutOps.repack([[a, .gap, b, c, d, .app("e")]], perPage: 4, free: true)
            == [[a, b, c, d], [.app("e")]])
    }

    @Test func freeReconcileLeavesACellForRemovedApps() {
        let installed = ["a", "c", "new"].map { app($0) }
        let result = LayoutOps.reconcile([[a, b, c, .gap]], installed: installed, hidden: [], perPage: 10, free: true)
        #expect(result == [[a, .gap, c, .app("new")]])
    }

    @Test func linedUpReconcileDropsGaps() {
        let installed = ["a", "c"].map { app($0) }
        #expect(LayoutOps.reconcile([[a, .gap, c]], installed: installed, hidden: [], perPage: 10) == [[a, c]])
    }

    @Test func regridKeepsRowAndColumn() {
        // 3 × 2 → 4 × 2: b on row 2, column 1 stays there.
        let pages: [[LayoutItem]] = [[a, .gap, .gap, b, .gap, c]]
        #expect(LayoutOps.regrid(pages, fromColumns: 3, toColumns: 4, rows: 2) == [[a, .gap, .gap, .gap, b, .gap, c]])
    }

    @Test func regridMovesIconsThatNoLongerFitIntoEmptyCells() {
        // 3 × 2 → 2 × 2: c in column 3 takes the first empty cell.
        let pages: [[LayoutItem]] = [[a, .gap, c, .gap, b]]
        #expect(LayoutOps.regrid(pages, fromColumns: 3, toColumns: 2, rows: 2) == [[a, c, .gap, b]])
    }

    @Test func regridCarriesOverflowToTheNextPage() {
        let pages: [[LayoutItem]] = [[a, b, c, d]]
        #expect(LayoutOps.regrid(pages, fromColumns: 2, toColumns: 1, rows: 2) == [[a, c], [b, d]])
    }

    @Test func regridBackAndForthRestoresTheLayout() {
        let pages: [[LayoutItem]] = [[a, .gap, b, .gap, .gap, c]]
        let wide = LayoutOps.regrid(pages, fromColumns: 3, toColumns: 5, rows: 2)
        #expect(LayoutOps.regrid(wide, fromColumns: 5, toColumns: 3, rows: 2) == pages)
    }
}
