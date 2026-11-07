import Testing
import AppKit
import CoreImage
@testable import LaunchUS

struct MotionCurveTests {
    @Test func endpointsAndLinear() {
        let linear = MotionCurve(x1: 0, y1: 0, x2: 1, y2: 1)
        #expect(abs(linear.value(at: 0)) < 0.001)
        #expect(abs(linear.value(at: 1) - 1) < 0.001)
        #expect(abs(linear.value(at: 0.3) - 0.3) < 0.01)
    }

    @Test func easeOutRunsAhead() {
        let easeOut = MotionCurve(x1: 0.16, y1: 1, x2: 0.3, y2: 1)
        #expect(easeOut.value(at: 0.3) > 0.6)
    }

    @Test func bounceOvershoots() {
        let bounce = MotionCurve(x1: 0.34, y1: 1.45, x2: 0.64, y2: 1)
        let peak = stride(from: 0.0, through: 1, by: 0.02).map(bounce.value).max() ?? 0
        #expect(peak > 1.02)
    }

    @Test func clampKeepsTimeForward() {
        let wild = MotionCurve(x1: -0.5, y1: 3, x2: 1.4, y2: -2).clamped
        #expect(wild.x1 == 0 && wild.x2 == 1)
        #expect(wild.y1 == MotionCurve.yRange.upperBound && wild.y2 == MotionCurve.yRange.lowerBound)
    }

    @Test @MainActor func backgroundResolutionStepsDown() {
        #expect(WallpaperProvider.Look(blur: 0, saturation: 1).resolution == 2)
        #expect(WallpaperProvider.Look(blur: 2, saturation: 1).resolution == 2)
        #expect(WallpaperProvider.Look(blur: 6, saturation: 1).resolution == 2.0 / 3)
        #expect(WallpaperProvider.Look(blur: 38, saturation: 1).resolution == 1.0 / 3)
    }
}

struct WallpaperBlurTests {
    /// A sharp black/white edge: it should spread wider the higher the blur, in screen points,
    /// with no jump where the working resolution steps down.
    @Test @MainActor func blurSoftensSteadily() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("checker.png")
        let size = 400
        let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: size, height: size))
        cg.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        try NSBitmapImageRep(cgImage: cg.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)

        let provider = WallpaperProvider()
        let context = CIContext()
        var last = -1.0
        for blur in [0.0, 1, 2, 3, 4, 6, 8, 12, 15, 25, 38, 80, 120] {
            let image = try #require(provider.render(url: url, source: "\(blur)", target: CGSize(width: 400, height: 400),
                                                     look: .init(blur: blur, saturation: 1), context: context))
            let spread = edgeWidth(image) * 400 / Double(image.width)
            if let out = ProcessInfo.processInfo.environment["LAUNCHUS_BLUR_DUMP"] {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: "\(out)/blur-\(Int(blur)).png"))
            }
            #expect(spread >= last, "blur \(blur): \(spread) after \(last)")
            print("edge width at blur \(blur): \(spread)")
            last = spread
        }
    }

    /// Pixels along the middle row that are neither nearly black nor nearly white.
    private func edgeWidth(_ image: CGImage) -> Double {
        let rep = NSBitmapImageRep(cgImage: image)
        let y = rep.pixelsHigh / 2
        return Double((0..<rep.pixelsWide).filter { x in
            let b = rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0
            return b > 0.12 && b < 0.85
        }.count)
    }
}
