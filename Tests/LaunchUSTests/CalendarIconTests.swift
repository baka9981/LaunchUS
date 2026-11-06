import AppKit
import Testing
@testable import LaunchUS

struct CalendarIconTests {
    @Test func drawsTheDateItIsGiven() throws {
        let image = try #require(IconRenderer.render(path: CalendarIcon.prefix + "2026-11-06"))
        #expect(image.width == IconRenderer.pixelSize)
        if let out = ProcessInfo.processInfo.environment["LAUNCHUS_ICON_OUT"] {
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }

    @Test func todayIsAnISODate() {
        #expect(CalendarIcon.today.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
    }
}
