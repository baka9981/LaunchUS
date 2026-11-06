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

    func prepare(for screen: NSScreen, blur: Double) {
        let settings = Settings.shared
        let chosen = settings.background == .image ? BackgroundImage.url(settings.backgroundImage) : nil
        guard let url = chosen ?? NSWorkspace.shared.desktopImageURL(for: screen) else {
            image = nil
            key = nil
            return
        }
        let size = screen.frame.size
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let newKey = "\(url.path)|\(Int(size.width))x\(Int(size.height))|\(modified?.timeIntervalSince1970 ?? 0)|\(Int(blur))"
        guard newKey != key else { return }
        key = newKey

        let context = self.context
        Task.detached(priority: .userInitiated) { [weak self] in
            let blurred = Self.blurred(url: url, target: size, blur: blur, context: context)
            await self?.finish(blurred, key: newKey)
        }
    }

    private func finish(_ blurred: CGImage?, key: String) {
        guard self.key == key else { return }
        image = blurred
    }

    /// Aspect-fills the wallpaper at a third of the screen size, then blurs it.
    /// The low resolution is invisible under a heavy blur and keeps this fast.
    /// With the blur off, the picture is kept sharp at Retina resolution instead.
    nonisolated private static func blurred(url: URL, target: CGSize, blur: Double, context: CIContext) -> CGImage? {
        let sharp = blur < 1
        let factor: CGFloat = sharp ? 2 : 1.0 / 3
        let outW = max(1, (target.width * factor).rounded())
        let outH = max(1, (target.height * factor).rounded())
        guard let decoded = decode(url: url, fill: CGSize(width: outW, height: outH)) else { return nil }
        let source = CIImage(cgImage: decoded)
        guard source.extent.width > 0, source.extent.height > 0 else { return nil }
        let scale = max(outW / source.extent.width, outH / source.extent.height)
        let scaled = source.samplingLinear().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: scaled.extent.minX + (scaled.extent.width - outW) / 2,
            y: scaled.extent.minY + (scaled.extent.height - outH) / 2,
            width: outW, height: outH
        )
        let output = (sharp ? scaled.cropped(to: crop) : scaled.cropped(to: crop)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blur / 3)
            .cropped(to: crop))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.05, kCIInputContrastKey: 1.08, kCIInputBrightnessKey: -0.03])
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
    /// How much of the frosted glass covers what's behind, 0…1.
    var glassStrength = 1.0
    var dim = 0.2
    @Environment(\.colorScheme) private var colorScheme

    /// The dark look darkens the background further, so icons and names stand out like in dark mode elsewhere.
    private var shade: Double {
        guard colorScheme == .dark, Settings.shared.darkenBackground else { return dim }
        return min(0.8, dim + 0.25)
    }

    var body: some View {
        ZStack {
            if !glass, let image = wallpaper.image {
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
                    .opacity(glass ? glassStrength : 1)
            }
            Color.black.opacity(shade)
        }
        .contentShape(Rectangle())
    }
}

/// Window mode's frosted panel, following the system's light or dark appearance.
struct WindowGlass: View {
    var body: some View {
        VisualEffectBackground(material: .popover)
            .contentShape(Rectangle())
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
