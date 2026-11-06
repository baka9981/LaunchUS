import AppKit
import UniformTypeIdentifiers

/// Something other than an app on the grid: a web address, a file or folder, or a shell
/// command. Shown, searched, tagged and put in folders like an app.
struct CustomItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case url, file, script

        var title: String {
            switch self {
            case .url: String(localized: "网址")
            case .file: String(localized: "文件或文件夹")
            case .script: String(localized: "脚本")
            }
        }

        var symbol: String {
            switch self {
            case .url: "globe"
            case .file: "doc"
            case .script: "terminal"
            }
        }
    }

    static let idPrefix = "custom:"

    var id: String
    var kind: Kind
    var name: String
    /// The address, the file path, or the command run by zsh.
    var target: String

    init(id: String = CustomItem.idPrefix + UUID().uuidString, kind: Kind, name: String, target: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.target = target
    }

    static func isCustom(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    var fileURL: URL? {
        guard kind == .file else { return nil }
        return URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
    }

    var webURL: URL? {
        guard kind == .url else { return nil }
        let text = target.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), url.scheme != nil { return url }
        return URL(string: "https://" + text)
    }

    var appItem: AppItem {
        let url = fileURL ?? webURL ?? URL(fileURLWithPath: "/bin/zsh")
        return AppItem(id: id, url: url, bundleID: nil, name: name,
                       searchNames: [name.lowercased(), target.lowercased()],
                       pinyinKeys: Pinyin.keys(for: name), category: nil, custom: kind)
    }
}

extension AppItem {
    var isCustom: Bool { custom != nil }

    /// What the icon is drawn from: the file itself, or a symbol for addresses and commands.
    var iconPath: String {
        switch custom {
        case .url: IconRenderer.symbolPrefix + "globe"
        case .script: IconRenderer.symbolPrefix + "terminal.fill"
        case .file, nil: url.path
        }
    }
}

/// `~/Library/Application Support/LaunchUS/custom.json`
enum CustomItemStore {
    static var url: URL { LayoutStore.directory.appendingPathComponent("custom.json") }

    static func load() -> [CustomItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CustomItem].self, from: data)) ?? []
    }

    static func save(_ items: [CustomItem]) {
        do {
            try FileManager.default.createDirectory(at: LayoutStore.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(items).write(to: url, options: .atomic)
        } catch {
            NSLog("LaunchUS: failed to save custom.json: \(error)")
        }
        ICloudSync.localChanged()
    }
}

enum CustomLauncher {
    /// Opens the address or file with its default app, or runs the command in the background.
    static func open(_ item: CustomItem) {
        switch item.kind {
        case .url:
            if let url = item.webURL { NSWorkspace.shared.open(url) }
        case .file:
            if let url = item.fileURL { NSWorkspace.shared.open(url) }
        case .script:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-lc", item.target]
            task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { process in
                if process.terminationStatus != 0 {
                    NSLog("LaunchUS: script \(item.name) exited with \(process.terminationStatus)")
                }
            }
            do { try task.run() } catch { NSLog("LaunchUS: failed to run \(item.name): \(error)") }
        }
    }
}

/// Icons picked by the user, kept in `~/Library/Application Support/LaunchUS/Icons`.
/// Apps themselves are never changed.
enum CustomIcons {
    static var directory: URL { LayoutStore.directory.appendingPathComponent("Icons", isDirectory: true) }

    /// Copies an image into the icons folder; returns the value stored in `AppMeta.icon`.
    static func importImage(_ source: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        // A new name each time, so the icon cache sees a different source.
        let name = UUID().uuidString + "." + ext
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        return name
    }

    /// Saves another app's icon as an .icns, drawn whole like an app icon; returns the stored name.
    /// ImageIO only writes .icns from standard sizes in the sRGB/RGBA layout, so draw them fresh.
    static func importAppIcon(_ app: URL, into directory: URL = CustomIcons.directory) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        let name = UUID().uuidString + ".icns"
        let url = directory.appendingPathComponent(name)
        let sides = [512, 1024]
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sides.count, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.fileWriteUnknown) }
        for side in sides {
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CocoaError(.fileWriteUnknown)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            let dpi = 72 * side / sides[0]
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return name
    }

    /// The icon path for an `AppMeta.icon` value: a symbol, or a file in the icons folder.
    static func path(for value: String) -> String {
        value.hasPrefix(IconRenderer.symbolPrefix) ? value : directory.appendingPathComponent(value).path
    }

    /// Deletes image files no longer used by any app.
    static func prune(keeping values: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !values.contains(file) {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
