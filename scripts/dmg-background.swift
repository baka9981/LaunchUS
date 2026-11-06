// Draws the installer window's background: the app on the left, an arrow, Applications
// on the right. Writes 1x and 2x PNGs; dmg.sh joins them into one HiDPI TIFF.
//   swift scripts/dmg-background.swift <out-dir>
import AppKit

let width = 660.0, height = 400.0
// Finder sometimes opens the window larger than the bounds dmg.sh saves. The picture
// is drawn from the window's top-left and not stretched, so the canvas reaches well past
// the layout and the wash carries on there instead of leaving white.
let canvasWidth = 1600.0, canvasHeight = 1000.0
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvasWidth * scale), pixelsHigh: Int(canvasHeight * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvasWidth, height: canvasHeight)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // The layout sits in the top-left corner; everything below draws in its coordinates.
    let bottom = NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.97, alpha: 1)
    bottom.setFill()
    NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight).fill()
    let shift = NSAffineTransform()
    shift.translateX(by: 0, yBy: canvasHeight - height)
    shift.concat()

    // Soft top-to-bottom wash with a faint blue glow behind the icons.
    NSGradient(colors: [NSColor(white: 0.99, alpha: 1), bottom])!
        .draw(in: NSRect(x: 0, y: 0, width: canvasWidth, height: height), angle: -90)
    NSGradient(colors: [NSColor(calibratedRed: 0.04, green: 0.52, blue: 1, alpha: 0.10), .clear])!
        .draw(fromCenter: NSPoint(x: width / 2, y: 215), radius: 0, toCenter: NSPoint(x: width / 2, y: 215), radius: 300, options: [])

    // Title.
    let title = NSAttributedString(string: "LaunchUS", attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .bold),
        .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ])
    title.draw(at: NSPoint(x: (width - title.size().width) / 2, y: height - 62))

    // Arrow between the two icons (icon centres are at x 170 and 490, y 200 from the top).
    let y = height - 200
    let blue = NSColor(calibratedRed: 0.04, green: 0.52, blue: 1, alpha: 1)
    let dots = NSBezierPath()
    for x in stride(from: 262.0, through: 378.0, by: 14) {
        dots.appendOval(in: NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
    }
    blue.withAlphaComponent(0.45).setFill()
    dots.fill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 386, y: y + 13))
    head.line(to: NSPoint(x: 400, y: y))
    head.line(to: NSPoint(x: 386, y: y - 13))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    blue.setStroke()
    head.stroke()

    // Hint under the icons.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let hint = NSAttributedString(string: "拖到「应用程序」即可安装  ·  Drag to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(white: 0.45, alpha: 1),
        .paragraphStyle: style,
    ])
    hint.draw(in: NSRect(x: 0, y: 48, width: width, height: 20))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! draw(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! draw(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
