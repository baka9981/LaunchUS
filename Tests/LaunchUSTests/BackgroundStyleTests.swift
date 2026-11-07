import Foundation
import Testing
@testable import LaunchUS

struct BackgroundStyleTests {
    @Test func clampKeepsEveryValueInRange() {
        let wild = BackgroundStyle(blur: 999, saturation: -1, dim: 2, glassStrength: 0, temperature: 5,
                                   tintHue: -3, tint: 9, grain: -1, vignette: 4).clamped
        #expect(wild.blur == 240 && wild.saturation == 0 && wild.dim == 0.6 && wild.glassStrength == 0.2)
        #expect(wild.temperature == 1 && wild.tintHue == 0 && wild.tint == 1 && wild.grain == 0 && wild.vignette == 1)
    }

    @Test func presetsAreDistinctAndValid() {
        let styles = BackgroundStyle.presets.map(\.style)
        #expect(styles.first == .standard)
        for (i, a) in styles.enumerated() {
            #expect(a == a.clamped)
            for b in styles[(i + 1)...] { #expect(!a.matches(b)) }
        }
    }

    @Test func matchIgnoresHueWithoutTint() {
        var a = BackgroundStyle.standard
        a.tintHue = 0.1
        #expect(a.matches(.standard))
        a.tint = 0.5
        #expect(!a.matches(.standard))
    }

    @Test func savedLooksSurviveEncoding() throws {
        let saved = [BackgroundStyle.Saved(name: "Mine", style: BackgroundStyle.presets[5].style)]
        let decoded = try JSONDecoder().decode([BackgroundStyle.Saved].self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
    }

    @Test func grainTileIsMadeOnce() throws {
        let tile = try #require(FilmGrain.image)
        #expect(tile.width == 256 && tile.height == 256)
        #expect(FilmGrain.image === tile)
    }
}

struct GridFillTests {
    private func pages(_ counts: [Int]) -> [[LayoutItem]] {
        var n = 0
        return counts.map { c in (0..<c).map { _ in n += 1; return LayoutItem.app("a\(n)") } }
    }

    @Test func fullPagesFillUpWhenTheGridGrows() {
        let filled = LayoutOps.fill(pages([30, 30, 12]), wasPerPage: 30, perPage: 35)
        #expect(filled.map(\.count) == [35, 35, 2])
        #expect(filled.joined().map(\.id) == pages([30, 30, 12]).joined().map(\.id))
    }

    @Test func shortPagesStayShort() {
        #expect(LayoutOps.fill(pages([30, 10, 30]), wasPerPage: 30, perPage: 35).map(\.count) == [35, 5, 30])
    }

    @Test func shrinkingThenGrowingRestoresPages() {
        let original = pages([35, 20])
        let shrunk = LayoutOps.repack(original, perPage: 30)
        #expect(LayoutOps.fill(shrunk, wasPerPage: 30, perPage: 35) == original)
    }
}
