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
