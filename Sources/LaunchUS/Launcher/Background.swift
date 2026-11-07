import AppKit
import CoreImage
import ImageIO
import Observation
import SwiftUI

/// Produces a blurred copy of the desktop wallpaper (or a chosen picture), the classic Launchpad background.
@MainActor @Observable
final class WallpaperProvider {
    private(set) var image: CGImage?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private let context = CIContext(options: [.cacheIntermediates: false])

    /// The last decoded picture, kept so dragging a slider only re-blurs instead of re-decoding a 6K file.
    @ObservationIgnored private nonisolated(unsafe) var decoded: (key: String, image: CGImage)?
    /// Work in flight and the newest request that came in meanwhile: sliders fire many times a
    /// second, and only the latest value matters.
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var queued: (() -> Void)?

    func prepare(for screen: NSScreen, blur: Double) {
        let settings = Settings.shared
        // Debug aid for website pictures: LAUNCHUS_WALLPAPER=/path.png stands in for the desktop picture.
        let demo = ProcessInfo.processInfo.environment["LAUNCHUS_WALLPAPER"].map { URL(fileURLWithPath: $0) }
        let chosen = demo ?? (settings.background == .image ? BackgroundImage.url(settings.backgroundImage) : nil)
        guard let url = chosen ?? NSWorkspace.shared.desktopImageURL(for: screen) else {
            image = nil
            key = nil
            return
        }
        let size = screen.frame.size
        let look = Look(blur: blur, saturation: settings.backgroundSaturation)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let source = "\(url.path)|\(Int(size.width))x\(Int(size.height))|\(modified?.timeIntervalSince1970 ?? 0)"
        let newKey = "\(source)|\(look.key)"
        guard newKey != key else { return }
        key = newKey

        let work = { [weak self] in
            guard let self else { return }
            self.busy = true
            let context = self.context
            Task.detached(priority: .userInitiated) { [weak self] in
                let blurred = self?.render(url: url, source: source, target: size, look: look, context: context)
                await self?.finish(blurred, key: newKey)
            }
        }
        if busy { queued = work } else { work() }
    }

    private func finish(_ blurred: CGImage?, key: String) {
        if self.key == key { image = blurred }
        busy = false
        if let next = queued {
            queued = nil
            next()
        }
    }

    /// What the background looks like, apart from which picture it is.
    struct Look: Sendable {
        /// Gaussian blur sigma in screen points (the setting's 0…240).
        var blur: Double
        /// 1 leaves the colours as they are, 0 is grey, 2 doubly vivid.
        var saturation: Double

        var key: String { "\(Int((blur * 4).rounded()))|\(Int((saturation * 100).rounded()))" }

        /// Working resolution relative to the screen: sharp pictures need Retina pixels, while a
        /// heavy blur hides any lack of them and is far cheaper at low resolution. Stepping it
        /// down gradually (the blur spanning at least 4 working pixels) keeps light blurs smooth
        /// instead of jumping from crisp to a blocky third-size image.
        var resolution: CGFloat {
            let steps: [CGFloat] = [1.0 / 3, 1.0 / 2, 2.0 / 3, 1, 2]
            return steps.first { CGFloat(blur) * $0 >= 4 } ?? 2
        }
    }

    /// Aspect-fills the picture at the working resolution, then blurs and tones it.
    nonisolated func render(url: URL, source: String, target: CGSize, look: Look, context: CIContext) -> CGImage? {
        let factor = look.resolution
        let outW = max(1, (target.width * factor).rounded())
        let outH = max(1, (target.height * factor).rounded())
        let decodeKey = "\(source)|\(Int(outW))"
        let picture: CGImage
        if let cached = decoded, cached.key == decodeKey {
            picture = cached.image
        } else {
            guard let fresh = Self.decode(url: url, fill: CGSize(width: outW, height: outH)) else { return nil }
            decoded = (decodeKey, fresh)
            picture = fresh
        }
        let input = CIImage(cgImage: picture)
        guard input.extent.width > 0, input.extent.height > 0 else { return nil }
        let scale = max(outW / input.extent.width, outH / input.extent.height)
        let scaled = input.samplingLinear().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: scaled.extent.minX + (scaled.extent.width - outW) / 2,
            y: scaled.extent.minY + (scaled.extent.height - outH) / 2,
            width: outW, height: outH
        )
        let sigma = look.blur * Double(factor)
        let blurred = sigma < 0.2 ? scaled.cropped(to: crop) : scaled.cropped(to: crop)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: crop)
        // A light touch of contrast keeps a blurred picture from looking washed out; none when sharp.
        let contrast = 1 + 0.08 * min(1, look.blur / 10)
        let output = blurred.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: look.saturation, kCIInputContrastKey: contrast, kCIInputBrightnessKey: -0.03 * min(1, look.blur / 10),
        ])
        return context.createCGImage(output, from: crop)
    }

    /// Decodes the image straight at roughly the size needed to cover `fill`. Wallpapers are
    /// often 6K; decoding them at full size first would briefly take hundreds of megabytes.
    nonisolated private static func decode(url: URL, fill: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              var h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return nil }
        // Orientations 5–8 are rotated a quarter turn.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&w, &h) }
        let scale = min(1, max(fill.width / w, fill.height / h))
        let maxPixel = Int((max(w, h) * scale).rounded(.up)) + 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct BackgroundView: View {
    let wallpaper: WallpaperProvider
    /// Frosted glass over what's behind the window instead of the wallpaper.
    var glass = false
    var style = BackgroundStyle.standard
    @Environment(\.colorScheme) private var colorScheme

    /// The dark look darkens the background further, so icons and names stand out like in dark mode elsewhere.
    private var shade: Double {
        guard colorScheme == .dark, Settings.shared.darkenBackground else { return style.dim }
        return min(0.8, style.dim + 0.25)
    }

    var body: some View {
        let picture = !glass ? wallpaper.image : nil
        ZStack {
            if let image = picture {
                // Sized by the screen, not the picture: a landscape picture on a portrait
                // screen would otherwise widen the whole launcher and push the grid aside.
                Color.clear
                    .overlay {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
            } else {
                // Wallpaper unreadable (e.g. video or rotating folder): blur what's behind instead.
                VisualEffectBackground()
                    .opacity(glass ? style.glassStrength : 1)
            }
            BackgroundToning(style: style, blends: picture != nil)
            Color.black.opacity(shade)
        }
        .compositingGroup()
        .contentShape(Rectangle())
    }
}

/// Colour cast, colour wash, darkened corners and film grain over the background. Drawn live
/// rather than baked into the blurred picture, so their sliders answer at once.
struct BackgroundToning: View {
    let style: BackgroundStyle
    /// Blend modes only reach a picture drawn by SwiftUI; over the system's frosted glass the
    /// colours are laid on plainly and more lightly instead.
    let blends: Bool

    static let warm = Color(red: 1, green: 0.55, blue: 0.15)
    static let cool = Color(red: 0.2, green: 0.5, blue: 1)

    var body: some View {
        ZStack {
            if style.temperature != 0 {
                (style.temperature > 0 ? Self.warm : Self.cool)
                    .opacity(abs(style.temperature) * (blends ? 0.75 : 0.3))
                    .blendMode(blends ? .softLight : .normal)
            }
            if style.tint > 0 {
                Color(hue: style.tintHue, saturation: 0.7, brightness: 0.75)
                    .opacity(style.tint * (blends ? 0.9 : 0.35))
                    .blendMode(blends ? .color : .normal)
            }
            if style.vignette > 0 {
                EllipticalGradient(colors: [.clear, .black.opacity(0.85 * style.vignette)],
                                   center: .center, startRadiusFraction: 0.25, endRadiusFraction: 0.78)
            }
            if style.grain > 0, let grain = FilmGrain.image {
                Image(decorative: grain, scale: 2)
                    .resizable(resizingMode: .tile)
                    .opacity(min(1, style.grain * 1.2))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A tile of random light and dark specks, transparent on average, for the grain slider.
enum FilmGrain {
    static let image: CGImage? = {
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        // A fixed-seed generator, so the grain doesn't change between launches.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(side * side) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let n = Double((seed >> 33) & 0xFFFF) / 65535 - 0.5   // -0.5…0.5
            // Squaring keeps most specks faint and a few strong, like real grain.
            let alpha = UInt8(min(255, (n * n * 4) * 200))
            let value: UInt8 = n > 0 ? 255 : 0
            // Premultiplied: colour × alpha.
            let c = UInt8(Int(value) * Int(alpha) / 255)
            pixels[i * 4] = c; pixels[i * 4 + 1] = c; pixels[i * 4 + 2] = c; pixels[i * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

/// Window mode's frosted panel, following the system's light or dark appearance.
/// Window mode's backdrop: the same Liquid Glass as the system Apps window, bright and clear with
/// its lit edge, rather than the flat grey of a visual-effect material.
struct WindowGlass: View {
    var body: some View {
        LiquidGlassBackground(cornerRadius: LauncherView.windowCornerRadius)
            .contentShape(Rectangle())
    }
}

private struct LiquidGlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.style = .regular
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
