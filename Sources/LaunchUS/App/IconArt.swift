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

    private static let appColors: [NSColor] = [
        NSColor(red: 0.04, green: 0.6, blue: 1, alpha: 1), NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(red: 1, green: 0.22, blue: 0.4, alpha: 1),
        NSColor(red: 1, green: 0.6, blue: 0.04, alpha: 1), NSColor(red: 0.65, green: 0.35, blue: 0.9, alpha: 1),
        NSColor(white: 0.62, alpha: 1),
    ]

    private static func fill(_ style: AppIconStyle, path: NSBezierPath, tile: NSRect) {
        let colors: [NSColor] = switch style {
        case .mono, .grid, .dots: [NSColor(white: 1, alpha: 1), NSColor(white: 0.93, alpha: 1)]
        case .blue: [NSColor(red: 0.1, green: 0.55, blue: 1, alpha: 1), NSColor(red: 0, green: 0.36, blue: 0.95, alpha: 1)]
        case .rocket: [NSColor(red: 0.8, green: 0.83, blue: 0.84, alpha: 1), NSColor(red: 0.47, green: 0.49, blue: 0.5, alpha: 1)]
        }
        NSGradient(colors: colors)?.draw(in: path, angle: -90)
    }

    private static func drawGlyph(_ style: AppIconStyle, tile: NSRect) {
        switch style {
        case .mono, .blue:
            // Four loops tilted towards the centre, like the corners of ⌘.
            let color: NSColor = style == .mono ? .black : .white
            color.setStroke()
            let w = tile.width
            let offset = w * 0.16, length = w * 0.215, girth = w * 0.14
            for (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                let loop = NSBezierPath(roundedRect: NSRect(x: -length / 2, y: -girth / 2, width: length, height: girth),
                                        xRadius: girth / 2, yRadius: girth / 2)
                var t = AffineTransform(translationByX: tile.midX + dx * offset, byY: tile.midY + dy * offset)
                t.rotate(byDegrees: dx * dy > 0 ? 45 : -45)
                loop.transform(using: t)
                loop.lineWidth = w * 0.06
                loop.stroke()
            }
        case .dots:
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
        case .grid:
            // Like the macOS 26 Apps icon: a frosted search bar over two rows of glassy app tiles.
            drawSearchBar(tile: tile)
            let w = tile.width
            let cell = w * 0.157
            for (i, color) in appColors.enumerated() {
                let col = CGFloat(i % 3), row = CGFloat(i / 3)
                let r = NSRect(x: tile.minX + w * (0.186 + col * 0.235),
                               y: tile.maxY - w * (0.441 + row * 0.216) - cell, width: cell, height: cell)
                drawGlassTile(r, color: color)
            }
        case .rocket:
            drawRocket(tile: tile)
        }
    }

    /// A rocket flying up and to the right (there is no rocket SF Symbol), dark on the grey tile.
    private static func drawRocket(tile: NSRect) {
        let w = tile.width * 1.2
        // Drawn pointing up around (0, 0), in units of the tile, then turned 45° to the right.
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * w, y: y * w) }
        let shape = NSBezierPath()
        // Body: a long pointed oval, narrower at the tail.
        shape.move(to: p(0, 0.33))
        shape.curve(to: p(0.11, 0.02), controlPoint1: p(0.085, 0.27), controlPoint2: p(0.118, 0.13))
        shape.curve(to: p(0.055, -0.15), controlPoint1: p(0.105, -0.06), controlPoint2: p(0.075, -0.11))
        shape.line(to: p(-0.055, -0.15))
        shape.curve(to: p(-0.11, 0.02), controlPoint1: p(-0.075, -0.11), controlPoint2: p(-0.105, -0.06))
        shape.curve(to: p(0, 0.33), controlPoint1: p(-0.118, 0.13), controlPoint2: p(-0.085, 0.27))
        shape.close()
        // Fins growing out of the body like swept-back wings (all outlines run clockwise, so they fill as one).
        for side: CGFloat in [-1, 1] {
            let fin = NSBezierPath()
            fin.move(to: p(side * 0.09, 0.06))
            fin.curve(to: p(side * 0.215, -0.18), controlPoint1: p(side * 0.175, 0.02), controlPoint2: p(side * 0.215, -0.08))
            fin.curve(to: p(side * 0.065, -0.12), controlPoint1: p(side * 0.17, -0.13), controlPoint2: p(side * 0.1, -0.115))
            fin.close()
            shape.append(side < 0 ? fin.reversed : fin)
        }
        // Flame: a drop just below the tail.
        shape.move(to: p(-0.042, -0.205))
        shape.curve(to: p(0.042, -0.205), controlPoint1: p(-0.03, -0.19), controlPoint2: p(0.03, -0.19))
        shape.curve(to: p(0, -0.335), controlPoint1: p(0.045, -0.26), controlPoint2: p(0.02, -0.3))
        shape.curve(to: p(-0.042, -0.205), controlPoint1: p(-0.02, -0.3), controlPoint2: p(-0.045, -0.26))
        shape.close()
        // Window: a hole (an oval runs anticlockwise, against the body, so the non-zero fill leaves it out).
        shape.append(NSBezierPath(ovalIn: NSRect(x: -0.045 * w, y: 0.085 * w, width: 0.09 * w, height: 0.09 * w)))
        shape.windingRule = .nonZero
        var t = AffineTransform(translationByX: tile.midX, byY: tile.midY)
        t.rotate(byDegrees: -45)
        shape.transform(using: t)
        NSColor(red: 0.2, green: 0.22, blue: 0.23, alpha: 1).setFill()
        shape.fill()
    }

    /// A frosted capsule with a magnifying glass, across the top of the icon.
    private static func drawSearchBar(tile: NSRect) {
        let w = tile.width
        let bar = NSRect(x: tile.minX + w * 0.154, y: tile.maxY - w * 0.186 - w * 0.18, width: w * 0.692, height: w * 0.18)
        let capsule = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = w * 0.012
        shadow.shadowOffset = NSSize(width: 0, height: -w * 0.004)
        shadow.set()
        NSGradient(colors: [NSColor(white: 0.76, alpha: 1), NSColor(white: 0.83, alpha: 1)])?.draw(in: capsule, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        // A lit rim, like the edge of glass.
        let rim = NSBezierPath(roundedRect: bar.insetBy(dx: w * 0.005, dy: w * 0.005),
                               xRadius: bar.height / 2, yRadius: bar.height / 2)
        rim.lineWidth = w * 0.01
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        NSColor.white.withAlphaComponent(0.75).setStroke()
        rim.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Magnifier: a ring and a short handle.
        let r = bar.height * 0.22
        let c = CGPoint(x: bar.minX + bar.height * 0.48, y: bar.midY + r * 0.25)
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = w * 0.017
        ring.stroke()
        let handle = NSBezierPath()
        handle.move(to: CGPoint(x: c.x + r * 0.72, y: c.y - r * 0.72))
        handle.line(to: CGPoint(x: c.x + r * 1.45, y: c.y - r * 1.45))
        handle.lineWidth = w * 0.022
        handle.lineCapStyle = .round
        handle.stroke()
    }

    /// One glassy app tile: lighter at the top, a soft glow of its colour and a bright rim.
    private static func drawGlassTile(_ r: NSRect, color: NSColor) {
        let radius = r.width * 0.26
        let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let light = color.blended(withFraction: 0.1, of: .white) ?? color
        let deep = color.blended(withFraction: 0.08, of: .black) ?? color
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.55)
        glow.shadowBlurRadius = r.width * 0.22
        glow.shadowOffset = NSSize(width: 0, height: -r.width * 0.04)
        glow.set()
        NSGradient(colors: [light, deep])?.draw(in: shape, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        // Gloss on the upper half and a bright rim, like glass catching light.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])?
            .draw(in: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
        let rim = NSBezierPath(roundedRect: r.insetBy(dx: r.width * 0.02, dy: r.width * 0.02),
                               xRadius: radius, yRadius: radius)
        rim.lineWidth = r.width * 0.05
        (color.blended(withFraction: 0.4, of: .white) ?? .white).withAlphaComponent(0.7).setStroke()
        rim.stroke()
        NSGraphicsContext.restoreGraphicsState()
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
