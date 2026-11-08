import AppKit
import ApplicationServices
import ServiceManagement

/// Open at login, through the system's login items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LaunchUS: login item change failed: \(error)")
        }
    }
}

enum Permissions {
    /// Accessibility is needed to take over the F4 / Launchpad key.
    static var accessibility: Bool { AXIsProcessTrusted() }
}

/// Swallows the F4 key and toggles the launcher instead: the Launchpad key on older Apple
/// keyboards, the Spotlight key on newer ones.
/// Needs Accessibility, because it has to stop the key reaching the system.
final class LaunchpadKeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let action: @MainActor @Sendable () -> Void

    /// 131: the Launchpad key; 129: the Spotlight key; 118: F4 when the keys act as standard
    /// function keys.
    private static let keyCodes: Set<Int64> = [131, 129, 118]

    init?(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        guard Permissions.accessibility else { return nil }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<LaunchpadKeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard Self.keyCodes.contains(code), flags.isEmpty else { return Unmanaged.passUnretained(event) }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { [action] in action() }
        }
        return nil
    }
}

/// Retains the active callback receiver while another thread replaces or invalidates it.
/// Only the reference is protected here; receivers still synchronize their mutable state.
final class LockedCallbackTarget<Target: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var target: Target?

    func snapshot() -> Target? {
        lock.withLock { target }
    }

    func replace(with next: Target) {
        let previous = lock.withLock {
            let previous = target
            target = next
            return previous
        }
        // A receiver's deinit may stop a device and wait for its callback. Release it
        // outside the lock so that callback can finish taking its own snapshot.
        withExtendedLifetime(previous) {}
    }

    func clear(ifMatching receiver: Target) {
        let previous: Target? = lock.withLock {
            guard target === receiver else { return nil }
            let previous = target
            target = nil
            return previous
        }
        withExtendedLifetime(previous) {}
    }
}

/// Pinch on the trackpad with a chosen number of fingers, read from the private
/// MultitouchSupport framework (the public gesture events don't report these to other apps).
/// Reports how far the pinch has got while the fingers move, so the launcher can follow them,
/// then whether it went far enough when they lift.
final class TrackpadPinch {
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    /// Fingers closing together (opens) or spreading apart (closes).
    enum Direction: Sendable { case pinchIn, spread }

    private static let current = LockedCallbackTarget<TrackpadPinch>()

    private let fingerCounts: Set<Int>
    /// Direction, progress and how many fingers are pinching.
    private let changed: @MainActor @Sendable (Direction, Double, Int) -> Void
    private let ended: @MainActor @Sendable (Direction, Bool) -> Void
    private var devices: [UnsafeMutableRawPointer] = []
    private var stop: Stop?

    /// One gesture in progress on one device: where each finger started.
    private struct Gesture {
        var start: [Int32: (Float, Float)] = [:]
        var direction: Direction?
        var progress = 0.0
        var done = false
    }
    // Keyed by device, since every trackpad (and Magic Mouse) reports through the same callback.
    private var gestures: [UnsafeMutableRawPointer: Gesture] = [:]
    private let lock = NSLock()

    /// Fraction of the starting spread the fingers must close to (or open past) to complete.
    static let inThreshold: Float = 0.75
    static let outThreshold: Float = 1.33
    /// Movement below this fraction is ignored, so resting fingers don't start anything.
    static let deadZone: Float = 0.05
    /// Lifting the fingers past this much of the way completes the gesture; less cancels it.
    static let commitProgress = 0.5

    /// The pinch-finger setting stores 3, 4 or 5, or this value for "4 or 5 fingers".
    static let fourOrFive = 45

    /// Finger counts that start a pinch for a pinch-finger setting.
    static func fingerCounts(for setting: Int) -> Set<Int> {
        setting == fourOrFive ? [4, 5] : [min(5, max(3, setting))]
    }

    /// - fingers: the finger counts to follow (see `fingerCounts(for:)`).
    init?(fingers: Set<Int>,
          changed: @escaping @MainActor @Sendable (Direction, Double, Int) -> Void,
          ended: @escaping @MainActor @Sendable (Direction, Bool) -> Void) {
        guard !fingers.isEmpty else { return nil }
        fingerCounts = fingers
        self.changed = changed
        self.ended = ended
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop") else { return nil }
        let createList = unsafeBitCast(createSym, to: CreateList.self)
        let register = unsafeBitCast(registerSym, to: Register.self)
        let start = unsafeBitCast(startSym, to: Start.self)
        stop = unsafeBitCast(stopSym, to: Stop.self)
        guard let list = createList()?.takeRetainedValue() as? [AnyObject], !list.isEmpty else { return nil }

        TrackpadPinch.current.replace(with: self)
        for device in list {
            let ptr = Unmanaged.passRetained(device).toOpaque()
            devices.append(ptr)
            register(ptr, { device, data, count, _, _ in
                TrackpadPinch.current.snapshot()?.frame(device, data, count: Int(count))
                return 0
            })
            start(ptr, 0)
        }
    }

    deinit {
        for ptr in devices {
            stop?(ptr)
            Unmanaged<AnyObject>.fromOpaque(ptr).release()
        }
    }

    func invalidate() {
        TrackpadPinch.current.clear(ifMatching: self)
    }

    /// Finger records are 96 bytes: the contact's identifier is an Int32 at offset 16, its
    /// normalised position two floats at offset 32.
    private func frame(_ device: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, count: Int) {
        let key = device ?? UnsafeMutableRawPointer(bitPattern: 1)!
        var fingers: [Int32: (Float, Float)] = [:]
        if let data {
            for i in 0..<count {
                let base = data + i * 96
                fingers[base.load(fromByteOffset: 16, as: Int32.self)] =
                    (base.load(fromByteOffset: 32, as: Float.self), base.load(fromByteOffset: 36, as: Float.self))
            }
        }
        lock.lock()
        defer { lock.unlock() }
        var gesture = gestures[key] ?? Gesture()
        defer { gestures[key] = fingers.count >= 2 ? gesture : nil }

        // Fingers land one after another: start over each time a new one arrives, so the
        // starting spread is the whole hand's.
        if fingers.keys.contains(where: { gesture.start[$0] == nil }) {
            finish(&gesture)
            gesture = Gesture(start: fingers)
            return
        }
        // Lifting fingers ends the gesture: complete it if it got far enough.
        if fingers.count < gesture.start.count || fingers.count < 2 {
            finish(&gesture)
            return
        }
        guard !gesture.done, fingerCounts.contains(gesture.start.count) else { return }
        let before = Self.spread(gesture.start.values.map { $0 })
        guard before > 0.02 else { return }
        let ratio = Self.spread(gesture.start.keys.map { fingers[$0]! }) / before

        if gesture.direction == nil {
            if ratio < 1 - Self.deadZone { gesture.direction = .pinchIn }
            else if ratio > 1 + Self.deadZone { gesture.direction = .spread }
            else { return }
        }
        let direction = gesture.direction!
        let progress = Self.progress(direction, ratio: ratio)
        if abs(progress - gesture.progress) > 0.01 || progress >= 1 {
            gesture.progress = progress
            let count = gesture.start.count
            DispatchQueue.main.async { [changed] in changed(direction, progress, count) }
        }
        if progress >= 1 {
            gesture.done = true
            DispatchQueue.main.async { [ended] in ended(direction, true) }
        }
    }

    /// How far a pinch has got, 0…1, from the fingers' spread relative to where they started.
    static func progress(_ direction: Direction, ratio: Float) -> Double {
        let raw = direction == .pinchIn
            ? (1 - ratio) / (1 - inThreshold)
            : (ratio - 1) / (outThreshold - 1)
        return Double(min(1, max(0, raw)))
    }

    /// Reports the end of a gesture that was being followed and hasn't completed yet.
    private func finish(_ gesture: inout Gesture) {
        guard let direction = gesture.direction, !gesture.done else { return }
        gesture.done = true
        let commit = gesture.progress >= Self.commitProgress
        DispatchQueue.main.async { [ended] in ended(direction, commit) }
    }

    /// Mean distance of the points from their centre.
    static func spread(_ points: [(Float, Float)]) -> Float {
        let cx = points.map(\.0).reduce(0, +) / Float(points.count)
        let cy = points.map(\.1).reduce(0, +) / Float(points.count)
        return points.map { hypotf($0.0 - cx, $0.1 - cy) }.reduce(0, +) / Float(points.count)
    }
}

/// The system's own Hot Corners (Desktop & Dock settings), read-only.
enum SystemHotCorners {
    private static func key(_ corner: HotCorner) -> String? {
        switch corner {
        case .topLeft: "tl"
        case .topRight: "tr"
        case .bottomLeft: "bl"
        case .bottomRight: "br"
        case .off: nil
        }
    }

    /// Whether macOS also does something when the pointer reaches this corner without a modifier key.
    static func isTaken(_ corner: HotCorner, defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.dock")) -> Bool {
        guard let key = key(corner), let defaults else { return false }
        // 0 and 1 mean no action.
        let action = defaults.integer(forKey: "wvous-\(key)-corner")
        let modifier = defaults.integer(forKey: "wvous-\(key)-modifier")
        return action > 1 && modifier == 0
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The system's own thumb-and-three-finger gestures in System Settings › Trackpad › More
/// Gestures: pinching opens Apps and spreading shows the desktop. They answer to 4 and 5
/// fingers, so a LaunchUS pinch with as many fingers runs them too.
enum SystemPinch {
    /// Warnings for a pinch-finger setting, empty when nothing else answers.
    static func conflicts(fingers: Int,
                          dock: UserDefaults? = UserDefaults(suiteName: "com.apple.dock"),
                          trackpads: [UserDefaults?] = [UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad"),
                                                        UserDefaults(suiteName: "com.apple.driver.AppleBluetoothMultitouch.trackpad")])
        -> [String] {
        let counts = TrackpadPinch.fingerCounts(for: fingers)
        // 2 means the system reads the gesture; missing means the default, which is on.
        func recognized(_ key: String) -> Bool {
            trackpads.contains { ($0?.object(forKey: key) as? Int ?? 2) == 2 }
        }
        guard counts.contains(4) && recognized("TrackpadFourFingerPinchGesture")
            || counts.contains(5) && recognized("TrackpadFiveFingerPinchGesture") else { return [] }
        func on(_ key: String) -> Bool { dock?.object(forKey: key) as? Bool ?? true }
        var result: [String] = []
        if on("showLaunchpadGestureEnabled") {
            result.append(String(localized: "捏合时系统的「App」手势也会打开，两者会同时出现。"))
        }
        if on("showDesktopGestureEnabled") {
            result.append(String(localized: "张开时系统的「显示桌面」手势也会触发。"))
        }
        return result
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Toggles the launcher when the pointer is pushed into a screen corner.
/// Driven by mouse-move events, so it costs nothing while the pointer is still.
@MainActor
final class HotCornerWatcher {
    private var monitors: [Any] = []
    private var dwell: DispatchWorkItem?
    private var armed = true
    var corner: HotCorner = .off { didSet { update() } }
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    private func update() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        dwell?.cancel()
        guard corner != .off else { return }
        // Global events come from other apps; the local monitor covers the launcher itself.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.check()
            return event
        }) { monitors.append(m) }
    }

    /// Distance from the pointer to the watched corner of the screen it's on. With several
    /// displays, a corner that touches another display doesn't count: the pointer passes
    /// through it instead of stopping there.
    private func distance() -> CGFloat {
        let p = NSEvent.mouseLocation
        let screens = NSScreen.screens.map(\.frame)
        guard let frame = screens.first(where: { NSMouseInRect(p, $0, false) }),
              let target = Self.point(of: corner, in: frame),
              Self.isOuterCorner(corner, of: frame, among: screens) else { return .infinity }
        return max(abs(p.x - target.x), abs(p.y - target.y))
    }

    nonisolated static func point(of corner: HotCorner, in f: CGRect) -> CGPoint? {
        switch corner {
        case .topLeft: CGPoint(x: f.minX, y: f.maxY)
        case .topRight: CGPoint(x: f.maxX, y: f.maxY)
        case .bottomLeft: CGPoint(x: f.minX, y: f.minY)
        case .bottomRight: CGPoint(x: f.maxX, y: f.minY)
        case .off: nil
        }
    }

    /// Whether no other display lies just past the corner, sideways or up/down from it.
    nonisolated static func isOuterCorner(_ corner: HotCorner, of frame: CGRect, among screens: [CGRect]) -> Bool {
        guard let c = point(of: corner, in: frame) else { return false }
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        // Points one step outside the screen next to the corner, still level with its edge.
        let inX: CGFloat = left ? 1 : -1, inY: CGFloat = top ? -1 : 1
        let beyond = [
            CGPoint(x: c.x - inX * 2, y: c.y + inY * 2),  // sideways
            CGPoint(x: c.x + inX * 2, y: c.y - inY * 2),  // up or down
            CGPoint(x: c.x - inX * 2, y: c.y - inY * 2),  // diagonally
        ]
        return !screens.contains { other in other != frame && beyond.contains { other.contains($0) } }
    }

    private func check() {
        let d = distance()
        if d <= 2 {
            guard armed, dwell == nil else { return }
            // A short dwell, so flicking across the corner doesn't trigger it.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dwell = nil
                if self.armed, self.distance() <= 2 {
                    self.armed = false
                    self.action()
                }
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            dwell?.cancel()
            dwell = nil
            if d > 30 { armed = true }
        }
    }
}

/// Counts quick clicks of one mouse button: n in a row, each soon after the last and close to
/// where the first one was, make a burst. Pure, so the timing can be tested.
struct ClickBurst {
    var count: Int
    /// Longest gap between two clicks of a burst.
    static let gap: TimeInterval = 0.4
    /// How far the pointer may wander between clicks.
    static let slop: CGFloat = 12
    private var clicks = 0
    private var last: TimeInterval = -.infinity
    private var start = CGPoint.zero

    init(count: Int) { self.count = count }

    /// Adds one click; true when it completes a burst (the count then starts over).
    mutating func click(at time: TimeInterval, _ point: CGPoint) -> Bool {
        if time - last > Self.gap || hypot(point.x - start.x, point.y - start.y) > Self.slop {
            clicks = 0
            start = point
        }
        last = time
        clicks += 1
        guard clicks >= count else { return false }
        clicks = 0
        last = -.infinity
        return true
    }
}

/// Toggles the launcher when one mouse button is clicked quickly n times. Watches the clicks
/// macOS lets other apps see; it never swallows them.
@MainActor
final class MouseClickWatcher {
    private var monitors: [Any] = []
    private var burst: ClickBurst
    private let button: ClickButton
    private let action: () -> Void

    init?(button: ClickButton, count: Int, action: @escaping () -> Void) {
        guard let number = button.number else { return nil }
        self.button = button
        burst = ClickBurst(count: max(2, count))
        self.action = action
        let mask: NSEvent.EventTypeMask = switch number {
        case 0: .leftMouseDown
        case 1: .rightMouseDown
        default: .otherMouseDown
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let n = event.buttonNumber, t = event.timestamp
            MainActor.assumeIsolated { self?.clicked(n, t) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.clicked(event.buttonNumber, event.timestamp)
            return event
        }) { monitors.append(m) }
    }

    func invalidate() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func clicked(_ number: Int, _ time: TimeInterval) {
        guard number == button.number, burst.click(at: time, NSEvent.mouseLocation) else { return }
        action()
    }
}
