import AppKit
import ApplicationServices

/// Reads the unread counts the Dock shows on its icons (Mail, Messages…), through the
/// Accessibility API. Only reads; needs the Accessibility permission the hotkeys already use.
@MainActor
final class DockBadges {
    /// Standardized app path → badge text ("3", "99+", "•").
    var onChange: (([String: String]) -> Void)?

    private var timer: Timer?
    private var reading = false
    private let queue = DispatchQueue(label: "LaunchUS.DockBadges", qos: .utility)

    /// Polls every two seconds while the launcher is on screen.
    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !reading, Permissions.accessibility else { return }
        reading = true
        queue.async { [weak self] in
            let badges = Self.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    self.onChange?(badges)
                }
            }
        }
    }

    nonisolated static func read() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var result: [String: String] = [:]
        for list in children(of: app) where string(list, kAXRoleAttribute) == kAXListRole {
            for item in children(of: list) {
                guard let label = string(item, "AXStatusLabel"), !label.isEmpty else { continue }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &value) == .success else { continue }
                let url: URL? = if let u = value as? URL { u } else if let s = value as? String { URL(string: s) } else { nil }
                guard let url, url.isFileURL else { continue }
                result[url.standardizedFileURL.path] = label
            }
        }
        return result
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// "12" + "3" → "15"; anything that isn't a number (a dot, "!") shows as a dot.
    nonisolated static func sum(_ labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        let numbers = labels.compactMap { Int($0.filter(\.isNumber)) }
        guard numbers.count == labels.count else { return "•" }
        let total = numbers.reduce(0, +)
        return total > 999 ? "999+" : String(total)
    }
}

/// A picture chosen as the launcher background, copied into LaunchUS's own data.
enum BackgroundImage {
    static var directory: URL { LayoutStore.directory.appendingPathComponent("Background", isDirectory: true) }

    static func url(_ name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies the picture in and removes the previous one; returns the stored name.
    static func importImage(_ source: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased())
        try fm.copyItem(at: source, to: directory.appendingPathComponent(name))
        for old in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where old != name {
            try? fm.removeItem(at: directory.appendingPathComponent(old))
        }
        return name
    }
}
