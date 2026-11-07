import Foundation

/// The background's whole look apart from which picture it is: blur, colour, darkness and texture.
struct BackgroundStyle: Codable, Equatable, Hashable, Sendable {
    /// Blur radius in screen points, 0…240.
    var blur = 38.0
    /// 1 as is, 0 grey, 2 doubly vivid.
    var saturation = 1.05
    /// Black overlay, 0…0.6.
    var dim = 0.2
    /// Frosted glass's opacity, 0.2…1.
    var glassStrength = 1.0
    /// -1 cool … 1 warm.
    var temperature = 0.0
    /// Hue of the colour wash, 0…1.
    var tintHue = 0.6
    /// Strength of the colour wash, 0…1.
    var tint = 0.0
    /// Film grain, 0…1.
    var grain = 0.0
    /// Darkened corners, 0…1.
    var vignette = 0.0

    static let standard = BackgroundStyle()

    var clamped: BackgroundStyle {
        var s = self
        s.blur = min(240, max(0, blur))
        s.saturation = min(2, max(0, saturation))
        s.dim = min(0.6, max(0, dim))
        s.glassStrength = min(1, max(0.2, glassStrength))
        s.temperature = min(1, max(-1, temperature))
        s.tintHue = min(1, max(0, tintHue))
        s.tint = min(1, max(0, tint))
        s.grain = min(1, max(0, grain))
        s.vignette = min(1, max(0, vignette))
        return s
    }

    /// Whether two looks are the same once rounded to what a slider can show, so a preset still
    /// reads as chosen after a value went through UserDefaults.
    func matches(_ other: BackgroundStyle) -> Bool {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
        return near(blur / 240, other.blur / 240) && near(saturation, other.saturation) && near(dim, other.dim)
            && near(glassStrength, other.glassStrength) && near(temperature, other.temperature)
            && near(tint, other.tint) && (tint < 0.005 || near(tintHue, other.tintHue))
            && near(grain, other.grain) && near(vignette, other.vignette)
    }

    struct Preset: Identifiable {
        let name: String.LocalizationValue
        let style: BackgroundStyle
        var id: String { title }
        var title: String { String(localized: name) }
    }

    static let presets: [Preset] = [
        Preset(name: "默认", style: .standard),
        Preset(name: "清透", style: BackgroundStyle(blur: 10, saturation: 1.15, dim: 0.1)),
        Preset(name: "柔雾", style: BackgroundStyle(blur: 110, saturation: 0.85, dim: 0.12, grain: 0.12)),
        Preset(name: "暖阳", style: BackgroundStyle(blur: 50, saturation: 1.1, dim: 0.14, temperature: 0.55, vignette: 0.25)),
        Preset(name: "冷夜", style: BackgroundStyle(blur: 60, saturation: 0.9, dim: 0.34, temperature: -0.55, vignette: 0.45)),
        Preset(name: "胶片", style: BackgroundStyle(blur: 26, saturation: 0.8, dim: 0.18, temperature: 0.25, grain: 0.5, vignette: 0.4)),
        Preset(name: "黑白", style: BackgroundStyle(blur: 40, saturation: 0, dim: 0.25, grain: 0.25)),
        Preset(name: "单色", style: BackgroundStyle(blur: 70, saturation: 1, dim: 0.2, tintHue: 0.6, tint: 0.75)),
    ]

    /// A look the user named and kept.
    struct Saved: Codable, Equatable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var style: BackgroundStyle
    }
}
