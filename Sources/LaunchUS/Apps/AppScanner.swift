import AppKit
import CoreServices

struct AppItem: Identifiable, Hashable {
    /// bundleID, or the file path for apps without one (e.g. Steam game shims).
    let id: String
    let url: URL
    let bundleID: String?
    /// Localized name shown under the icon.
    let name: String
    /// Lowercased names used for plain-text matching.
    let searchNames: [String]
    /// Pinyin / initials keys used for romanized matching.
    let pinyinKeys: [String]
    /// `LSApplicationCategoryType`, used to name new folders.
    let category: String?
    /// Set for launch items that aren't apps (web addresses, files, commands).
    var custom: CustomItem.Kind? = nil
    /// Can be moved to the Trash from jiggle mode (not a system app).
    var isRemovable = false
    /// When the app arrived in its folder, and when it was last opened (Spotlight), for sorting.
    var addedDate: Date?
    var lastUsedDate: Date?
    /// How many times the app has been opened (Spotlight's use count).
    var useCount = 0

    /// The same app shown under another name; the original name stays searchable.
    func renamed(_ newName: String) -> AppItem {
        var copy = AppItem(id: id, url: url, bundleID: bundleID, name: newName,
                           searchNames: searchNames + [newName.lowercased()],
                           pinyinKeys: pinyinKeys + Pinyin.keys(for: newName), category: category, custom: custom)
        copy.isRemovable = isRemovable
        copy.addedDate = addedDate
        copy.lastUsedDate = lastUsedDate
        copy.useCount = useCount
        return copy
    }
}

enum AppScanner {
    static var roots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            // Safari: /Applications/Safari.app is a hidden link here, so the scan above skips it.
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ] + Settings.extraAppFolderPaths.map { URL(fileURLWithPath: $0) }
    }

    private static let maxDepth = 4

    static func scan() -> [AppItem] {
        let fm = FileManager.default
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [AppItem] = []
        // Debug aid for website pictures: LAUNCHUS_DEMO=1 lists only the apps every Mac ships with.
        let demo = ProcessInfo.processInfo.environment["LAUNCHUS_DEMO"] != nil

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isAliasFileKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                if enumerator.level > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }
                guard let target = appURL(url) else { continue }
                guard let item = makeItem(at: target) else { continue }
                if item.bundleID != nil, item.bundleID == ownID { continue }
                if demo, !target.path.hasPrefix("/System/") { continue }
                if seen.insert(item.id).inserted {
                    result.append(item)
                }
            }
        }

        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The app a found item stands for: an .app bundle itself, or one a Finder alias or
    /// symbolic link points to (an alias to an app kept elsewhere counts as installed here).
    static func appURL(_ url: URL) -> URL? {
        if url.pathExtension == "app" { return url.resolvingSymlinksInPath() }
        guard (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
              let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
              resolved.pathExtension == "app" else { return nil }
        return resolved.resolvingSymlinksInPath()
    }

    static func makeItem(at url: URL) -> AppItem? {
        let info = infoDictionary(for: url)
        if (info["LSBackgroundOnly"] as? Bool) == true { return nil }

        let bundleID = info["CFBundleIdentifier"] as? String
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }

        var names = [name, url.deletingPathExtension().lastPathComponent]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info[key] as? String, !value.isEmpty { names.append(value) }
        }
        names = unique(names)

        var item = AppItem(
            id: bundleID ?? url.path,
            url: url,
            bundleID: bundleID,
            name: name,
            searchNames: unique(names.map { $0.lowercased() }),
            pinyinKeys: unique(names.flatMap(Pinyin.keys(for:))),
            category: info["LSApplicationCategoryType"] as? String
        )
        item.isRemovable = isRemovable(url, bundleID: bundleID)
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        item.addedDate = values?.addedToDirectoryDate ?? values?.creationDate
        if let md = MDItemCreateWithURL(nil, url as CFURL) {
            item.lastUsedDate = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
            item.useCount = (MDItemCopyAttribute(md, "kMDItemUseCount" as CFString) as? Int) ?? 0
        }
        return item
    }

    /// Apps that ship with macOS can't be trashed; Safari lives in /Applications but is one of them.
    private static let systemBundleIDs: Set<String> = ["com.apple.Safari"]

    private static func isRemovable(_ url: URL, bundleID: String?) -> Bool {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/") else { return false }
        if let bundleID, systemBundleIDs.contains(bundleID) { return false }
        return FileManager.default.isDeletableFile(atPath: path)
    }

    /// Reads Info.plist directly (no Bundle cache, so updated apps are picked up).
    /// Handles both macOS bundles and wrapped iOS apps.
    private static func infoDictionary(for url: URL) -> [String: Any] {
        var candidates = [
            url.appendingPathComponent("Contents/Info.plist"),
            url.appendingPathComponent("WrappedBundle/Info.plist"),
        ]
        let wrapper = url.appendingPathComponent("Wrapper")
        if let inner = try? FileManager.default.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) {
            candidates.append(inner.appendingPathComponent("Info.plist"))
        }
        for plist in candidates {
            if let dict = NSDictionary(contentsOf: plist) as? [String: Any] { return dict }
        }
        return [:]
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum IconRenderer {
    /// Pixel size of cached icons; covers ~112pt icons on Retina screens.
    static let pixelSize = 224
    /// Icon paths starting with this draw an SF Symbol on a coloured tile instead of a file's icon.
    static let symbolPrefix = "symbol:"
    /// Icon paths starting with this draw the icon's dark version, where it has one.
    static let darkPrefix = "dark:"

    static func render(path: String) -> CGImage? {
        var path = path
        let dark = path.hasPrefix(darkPrefix)
        if dark { path.removeFirst(darkPrefix.count) }
        let px = pixelSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let full = NSRect(x: 0, y: 0, width: px, height: px)
        // The visible tile of a macOS icon: ~10% margin on each side.
        let tile = full.insetBy(dx: CGFloat(px) * 0.1, dy: CGFloat(px) * 0.1)
        let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        if path.hasPrefix(CalendarIcon.prefix) {
            CalendarIcon.draw(String(path.dropFirst(CalendarIcon.prefix.count)), in: tile, shape: shape, dark: dark)
        } else if path.hasPrefix(symbolPrefix) {
            drawSymbol(String(path.dropFirst(symbolPrefix.count)), in: tile, shape: shape)
        } else if path.hasPrefix(CustomIcons.directory.path + "/"), !["icns", "app"].contains((path as NSString).pathExtension.lowercased()),
                  let image = NSImage(contentsOfFile: path) {
            // A picked picture: cropped to the tile, like an app icon.
            NSGraphicsContext.current?.saveGraphicsState()
            shape.addClip()
            let size = image.size
            let scale = max(tile.width / max(size.width, 1), tile.height / max(size.height, 1))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: NSRect(x: tile.midX - drawn.width / 2, y: tile.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            NSGraphicsContext.current?.restoreGraphicsState()
        } else if path.hasPrefix(CustomIcons.directory.path + "/"), let image = NSImage(contentsOfFile: path) {
            image.draw(in: full)
        } else if let image = SystemIcon.image(bundle: path, pixels: px, dark: dark) {
            // IconServices draws apps the way the Dock and the system Apps window do: the lit glass edge and brighter face.
            ctx.draw(image, in: full)
        } else {
            NSWorkspace.shared.icon(forFile: path).draw(in: full)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Tile colours for symbol icons, picked by the symbol name.
    private static let palette: [(NSColor, NSColor)] = [
        (NSColor(red: 0.25, green: 0.6, blue: 1, alpha: 1), NSColor(red: 0.05, green: 0.36, blue: 0.9, alpha: 1)),
        (NSColor(red: 0.3, green: 0.3, blue: 0.34, alpha: 1), NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)),
        (NSColor(red: 1, green: 0.62, blue: 0.2, alpha: 1), NSColor(red: 0.95, green: 0.38, blue: 0.1, alpha: 1)),
        (NSColor(red: 0.35, green: 0.85, blue: 0.5, alpha: 1), NSColor(red: 0.1, green: 0.62, blue: 0.3, alpha: 1)),
        (NSColor(red: 0.75, green: 0.45, blue: 1, alpha: 1), NSColor(red: 0.5, green: 0.2, blue: 0.85, alpha: 1)),
        (NSColor(red: 1, green: 0.4, blue: 0.5, alpha: 1), NSColor(red: 0.88, green: 0.15, blue: 0.32, alpha: 1)),
    ]

    static func tileColors(for symbol: String) -> (NSColor, NSColor) {
        switch symbol {
        case "globe": return palette[0]
        case "terminal.fill": return palette[1]
        default: return palette[symbol.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff } % palette.count]
        }
    }

    private static func drawSymbol(_ name: String, in tile: NSRect, shape: NSBezierPath) {
        let (top, bottom) = tileColors(for: name)
        NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.46, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                               width: size.width, height: size.height))
    }
}

/// Calendar's icon showing today's date, like the one in the Dock.
enum CalendarIcon {
    static let bundleID = "com.apple.iCal"
    /// Icon paths starting with this draw the calendar for the date that follows.
    static let prefix = "calendar:"

    static var today: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Draws a white tile with the month in red and the day of the month below it.
    static func draw(_ day: String, in tile: NSRect, shape: NSBezierPath, dark: Bool = false) {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        if parts.count == 3 { (components.year, components.month, components.day) = (parts[0], parts[1], parts[2]) }
        let date = Calendar.current.date(from: components) ?? Date()

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = tile.width * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -tile.width * 0.012)
        shadow.set()
        (dark ? NSColor(white: 0.1, alpha: 1) : .white).setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(colors: dark ? [NSColor(white: 0.2, alpha: 1), NSColor(white: 0.08, alpha: 1)]
                                : [.white, NSColor(white: 0.93, alpha: 1)])?.draw(in: shape, angle: -90)

        let month = DateFormatter()
        month.setLocalizedDateFormatFromTemplate("MMM")
        let monthText = NSAttributedString(string: month.string(from: date).uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: tile.height * 0.15, weight: .semibold),
            .foregroundColor: NSColor(red: 0.98, green: 0.24, blue: 0.22, alpha: 1),
        ])
        let monthSize = monthText.size()
        monthText.draw(at: NSPoint(x: tile.midX - monthSize.width / 2, y: tile.maxY - tile.height * 0.08 - monthSize.height))

        let dayText = NSAttributedString(string: "\(Calendar.current.component(.day, from: date))", attributes: [
            .font: NSFont.systemFont(ofSize: tile.height * 0.5, weight: .light),
            .foregroundColor: NSColor(white: dark ? 0.95 : 0.12, alpha: 1),
        ])
        let daySize = dayText.size()
        dayText.draw(at: NSPoint(x: tile.midX - daySize.width / 2, y: tile.minY + tile.height * 0.4 - daySize.height / 2))
    }
}

/// An app's icon drawn by IconServices the way the Dock does, light or dark.
/// Its classes are private, so each step checks they still answer and gives nil otherwise.
enum SystemIcon {
    private static let loaded: Bool = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW) != nil

    static func image(bundle path: String, pixels: Int, dark: Bool) -> CGImage? {
        guard loaded, path.hasSuffix(".app") || path.hasSuffix(".app/"),
              let iconClass = NSClassFromString("ISBundleIcon") as? NSObject.Type,
              let descriptorClass = NSClassFromString("ISImageDescriptor") as? NSObject.Type else { return nil }
        let initIcon = NSSelectorFromString("initWithBundleURL:")
        let initDescriptor = NSSelectorFromString("initWithSize:scale:")
        let prepare = NSSelectorFromString("prepareImagesForImageDescriptors:")
        let imageFor = NSSelectorFromString("imageForDescriptor:")
        let cgImage = NSSelectorFromString("CGImage")
        guard iconClass.instancesRespond(to: initIcon), iconClass.instancesRespond(to: prepare),
              iconClass.instancesRespond(to: imageFor), descriptorClass.instancesRespond(to: initDescriptor),
              descriptorClass.instancesRespond(to: NSSelectorFromString("setAppearance:")) else { return nil }

        // alloc and init each hand over a reference, which init consumes and the caller then owns.
        let alloc = NSSelectorFromString("alloc")
        guard let blankIcon = (iconClass as AnyObject).perform(alloc)?.takeUnretainedValue(),
              let icon = blankIcon.perform(initIcon, with: URL(fileURLWithPath: path) as NSURL)?
                  .takeRetainedValue() as? NSObject,
              let blankDescriptor = (descriptorClass as AnyObject).perform(alloc)?.takeUnretainedValue() else { return nil }
        typealias InitDescriptor = @convention(c) (AnyObject, Selector, CGSize, CGFloat) -> Unmanaged<NSObject>?
        let makeDescriptor = unsafeBitCast(class_getMethodImplementation(descriptorClass, initDescriptor), to: InitDescriptor.self)
        let points = CGFloat(pixels) / 2
        guard let descriptor = makeDescriptor(blankDescriptor, initDescriptor, CGSize(width: points, height: points), 2)?
            .takeRetainedValue() else { return nil }
        descriptor.setValue(dark ? 1 : 0, forKey: "appearance")
        _ = icon.perform(prepare, with: [descriptor])
        guard let image = icon.perform(imageFor, with: descriptor)?.takeUnretainedValue() as? NSObject,
              image.responds(to: cgImage) else { return nil }
        typealias GetImage = @convention(c) (AnyObject, Selector) -> Unmanaged<CGImage>?
        let get = unsafeBitCast(class_getMethodImplementation(type(of: image), cgImage), to: GetImage.self)
        return get(image, cgImage)?.takeUnretainedValue()
    }
}
