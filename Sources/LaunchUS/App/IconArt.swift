import AppKit

/// The four selectable app icons, drawn in code.
enum IconArt {
    static func image(_ style: AppIconStyle, size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(style, in: rect)
            return true
        }
    }

    private static func draw(_ style: AppIconStyle, in rect: NSRect) {
        // macOS icon grid: the tile is 824/1024 of the canvas, with a soft shadow below.
        let s = rect.width
        let tile = NSRect(x: s * 0.0977, y: s * 0.0977 + s * 0.008, width: s * 0.8047, height: s * 0.8047)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = s * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
        shadow.set()
        fill(style, path: path, tile: tile)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        fill(style, path: path, tile: tile)
        drawGlyph(style, tile: tile)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.12).setStroke()
        path.lineWidth = max(1, s * 0.002)
        path.stroke()
    }

    private static func fill(_ style: AppIconStyle, path: NSBezierPath, tile: NSRect) {
        let colors: [NSColor] = switch style {
        case .mono, .grid: [NSColor(white: 1, alpha: 1), NSColor(white: 0.93, alpha: 1)]
        case .blue: [NSColor(red: 0.1, green: 0.55, blue: 1, alpha: 1), NSColor(red: 0, green: 0.36, blue: 0.95, alpha: 1)]
        case .rocket: [NSColor(white: 0.62, alpha: 1), NSColor(white: 0.3, alpha: 1)]
        }
        NSGradient(colors: colors)?.draw(in: path, angle: -90)
    }

    private static func drawGlyph(_ style: AppIconStyle, tile: NSRect) {
        switch style {
        case .mono, .blue:
            // Four rings in a square, the "launcher" mark.
            let color: NSColor = style == .mono ? .black : .white
            color.setStroke()
            let r = tile.width * 0.1
            let gap = tile.width * 0.13
            for (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                let c = CGPoint(x: tile.midX + dx * gap, y: tile.midY + dy * gap)
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ring.lineWidth = tile.width * 0.06
                ring.stroke()
            }
        case .grid:
            // A 3 × 3 grid of colourful app tiles.
            let colors: [NSColor] = [
                .systemGreen, .systemYellow, .systemOrange,
                .systemRed, NSColor(white: 0.72, alpha: 1), .systemPink,
                .systemPurple, .systemBlue, .systemTeal,
            ]
            let cell = tile.width * 0.17
            let gap = tile.width * 0.07
            let total = cell * 3 + gap * 2
            for i in 0..<9 {
                let col = CGFloat(i % 3), row = CGFloat(i / 3)
                let r = NSRect(x: tile.midX - total / 2 + col * (cell + gap),
                               y: tile.midY + total / 2 - cell - row * (cell + gap), width: cell, height: cell)
                colors[i].setFill()
                NSBezierPath(roundedRect: r, xRadius: cell * 0.26, yRadius: cell * 0.26).fill()
            }
        case .rocket:
            let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .regular)
                .applying(.init(paletteColors: [NSColor(white: 0.18, alpha: 1)]))
            let symbol = (NSImage(systemSymbolName: "rocket.fill", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil))?
                .withSymbolConfiguration(config)
            if let symbol {
                let size = symbol.size
                let scale = tile.width * 0.56 / max(size.width, size.height)
                let w = size.width * scale, h = size.height * scale
                symbol.draw(in: NSRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h))
            }
        }
    }

    /// Writes an .iconset folder (for `iconutil`), used by the build script.
    static func writeIconset(_ style: AppIconStyle, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                draw(style, in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
