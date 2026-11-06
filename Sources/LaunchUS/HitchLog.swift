import AppKit
import QuartzCore

/// Debug aid: LAUNCHUS_HITCHES=/path.log writes each late frame of the launcher there
/// (its length, how many frames it cost), to find stutters `sample` can't show.
@MainActor
final class HitchLog: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private let handle: FileHandle
    private let label: () -> String

    init?(view: NSView, label: @escaping () -> String) {
        guard let path = ProcessInfo.processInfo.environment["LAUNCHUS_HITCHES"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
        self.label = label
        super.init()
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let frame = link.targetTimestamp - link.timestamp
        defer { last = now }
        guard last > 0, frame > 0 else { return }
        let gap = now - last
        // Idle gaps (nothing on screen changing) are long too; only count up to half a second.
        guard gap > frame * 1.8, gap < 0.5 else { return }
        let line = String(format: "%.3f %5.1fms %2d frames  %@\n", now, gap * 1000, Int((gap / frame).rounded()) - 1, label())
        handle.write(Data(line.utf8))
    }
}
