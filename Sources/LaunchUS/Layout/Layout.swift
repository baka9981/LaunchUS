import Foundation
import SwiftUI

struct Folder: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var apps: [String]
    /// Set for smart folders: a search such as "#设计 #常用" that decides the contents; `apps` stays empty.
    var query: String?
    /// Tint of the folder tile, a `FolderColor` raw value; nil is the plain glass.
    var color: String?

    init(id: String = UUID().uuidString, name: String, apps: [String], query: String? = nil) {
        self.id = id
        self.name = name
        self.apps = apps
        self.query = query
    }

    var isSmart: Bool { query != nil }
}

enum FolderColor: String, CaseIterable {
    case red, orange, yellow, green, mint, blue, purple, pink, gray

    var color: Color {
        switch self {
        case .red: Color(red: 1, green: 0.27, blue: 0.23)
        case .orange: Color(red: 1, green: 0.58, blue: 0)
        case .yellow: Color(red: 1, green: 0.8, blue: 0)
        case .green: Color(red: 0.2, green: 0.78, blue: 0.35)
        case .mint: Color(red: 0, green: 0.78, blue: 0.75)
        case .blue: Color(red: 0, green: 0.48, blue: 1)
        case .purple: Color(red: 0.69, green: 0.32, blue: 0.87)
        case .pink: Color(red: 1, green: 0.18, blue: 0.33)
        case .gray: Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }

    var title: String {
        switch self {
        case .red: String(localized: "红色")
        case .orange: String(localized: "橙色")
        case .yellow: String(localized: "黄色")
        case .green: String(localized: "绿色")
        case .mint: String(localized: "薄荷绿")
        case .blue: String(localized: "蓝色")
        case .purple: String(localized: "紫色")
        case .pink: String(localized: "粉色")
        case .gray: String(localized: "灰色")
        }
    }
}

/// One cell of the home grid.
enum LayoutItem: Codable, Hashable, Identifiable {
    case app(String)
    case folder(Folder)

    var id: String {
        switch self {
        case .app(let id): "app:" + id
        case .folder(let folder): "folder:" + folder.id
        }
    }

    var appIDs: [String] {
        switch self {
        case .app(let id): [id]
        case .folder(let folder): folder.apps
        }
    }
}

/// Per-app extras, edited from the right-click menu.
struct AppMeta: Codable, Hashable {
    /// Name shown under the icon instead of the app's own.
    var displayName: String?
    /// Extra names that only matter to search.
    var aliases: [String] = []
    /// Tag names.
    var tags: [String] = []
    var hidden = false
    /// Icon picked by the user: an SF Symbol ("symbol:…") or an image file in `CustomIcons`.
    var icon: String?
    /// Global shortcut that opens the app from anywhere (`AppHotKeys`).
    var shortcut: HotKeySpec?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        shortcut = try c.decodeIfPresent(HotKeySpec.self, forKey: .shortcut)
    }
}

/// `~/Library/Application Support/LaunchUS/{layout,meta}.json`
enum LayoutStore {
    struct LayoutFile: Codable {
        var version = 1
        var pages: [[LayoutItem]]
    }

    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchUS", isDirectory: true)
    }
    static var layoutURL: URL { directory.appendingPathComponent("layout.json") }
    static var metaURL: URL { directory.appendingPathComponent("meta.json") }

    static func loadLayout() -> [[LayoutItem]]? {
        guard let data = try? Data(contentsOf: layoutURL) else { return nil }
        return (try? JSONDecoder().decode(LayoutFile.self, from: data))?.pages
    }

    static func loadMeta() -> [String: AppMeta] {
        guard let data = try? Data(contentsOf: metaURL) else { return [:] }
        return (try? JSONDecoder().decode([String: AppMeta].self, from: data)) ?? [:]
    }

    static func save(layout: [[LayoutItem]]) {
        write(LayoutFile(pages: layout), to: layoutURL)
        AutoBackup.schedule()
        ICloudSync.localChanged()
    }

    static func save(meta: [String: AppMeta]) {
        write(meta.filter { $0.value != AppMeta() }, to: metaURL)
        AutoBackup.schedule()
        ICloudSync.localChanged()
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("LaunchUS: failed to save \(url.lastPathComponent): \(error)")
        }
    }
}

enum LayoutOps {
    /// Drops uninstalled / hidden apps, appends new apps at the end, and repacks pages
    /// so none exceeds `perPage`. Empty pages are removed.
    static func reconcile(_ pages: [[LayoutItem]], installed: [AppItem], hidden: Set<String>, perPage: Int) -> [[LayoutItem]] {
        let valid = Set(installed.map(\.id)).subtracting(hidden)
        var placed = Set<String>()

        var result: [[LayoutItem]] = pages.map { page in
            page.compactMap { item in
                switch item {
                case .app(let id):
                    guard valid.contains(id), placed.insert(id).inserted else { return nil }
                    return item
                case .folder(var folder):
                    if folder.isSmart { return item }
                    folder.apps = folder.apps.filter { valid.contains($0) && placed.insert($0).inserted }
                    return folder.apps.isEmpty ? nil : .folder(folder)
                }
            }
        }

        let newApps = installed.filter { valid.contains($0.id) && !placed.contains($0.id) }
        if !newApps.isEmpty {
            if result.isEmpty { result = [[]] }
            result[result.count - 1].append(contentsOf: newApps.map { .app($0.id) })
        }
        return repack(result, perPage: perPage)
    }

    /// Pushes overflow forward page by page and removes empty pages.
    static func repack(_ pages: [[LayoutItem]], perPage: Int) -> [[LayoutItem]] {
        var result = pages
        var i = 0
        while i < result.count {
            if result[i].count > perPage {
                let overflow = Array(result[i][perPage...])
                result[i].removeLast(result[i].count - perPage)
                if i + 1 < result.count {
                    result[i + 1].insert(contentsOf: overflow, at: 0)
                } else {
                    result.append(overflow)
                }
            }
            i += 1
        }
        result.removeAll { $0.isEmpty }
        return result
    }

    /// Default layout: everything alphabetically, like a fresh Launchpad.
    static func alphabetical(_ apps: [AppItem], perPage: Int) -> [[LayoutItem]] {
        repack([apps.map { .app($0.id) }], perPage: perPage)
    }
}

/// Folder names for apps' `LSApplicationCategoryType`, used when dropping one app onto another.
enum AppCategoryName {
    static func folderName(for categories: [String?]) -> String {
        let known = categories.compactMap { $0 }
        if let first = known.first, known.allSatisfy({ $0 == first }), let name = names[first] {
            return name
        }
        return String(localized: "未命名文件夹")
    }

    /// Tag name for a category, used for the one-time initial tags.
    static func tagName(for category: String?) -> String? {
        category.flatMap { names[$0] }
    }

    /// The broad groups of the system Apps window's category tabs, in its order.
    enum Group: String, CaseIterable {
        case developer, utilities, social, productivity, creativity, entertainment, photoVideo, reading, other

        var title: String {
            switch self {
            case .developer: String(localized: "开发者工具")
            case .utilities: String(localized: "工具")
            case .social: String(localized: "社交")
            case .productivity: String(localized: "效率与财务")
            case .creativity: String(localized: "创意")
            case .entertainment: String(localized: "娱乐")
            case .photoVideo: String(localized: "照片与视频")
            case .reading: String(localized: "信息与阅读")
            case .other: String(localized: "其他")
            }
        }
    }

    static func group(for category: String?) -> Group {
        guard let category = category?.replacingOccurrences(of: "public.app-category.", with: "") else { return .other }
        if category.hasSuffix("games") { return .entertainment }
        switch category {
        case "developer-tools": return .developer
        case "utilities": return .utilities
        case "social-networking": return .social
        case "productivity", "business", "finance": return .productivity
        case "graphics-design": return .creativity
        case "entertainment", "music", "sports": return .entertainment
        case "photography", "video": return .photoVideo
        case "news", "reference", "education", "weather", "books", "magazines": return .reading
        default: return .other
        }
    }

    private static let names: [String: String] = [
        "public.app-category.developer-tools": String(localized: "开发工具"),
        "public.app-category.productivity": String(localized: "效率"),
        "public.app-category.utilities": String(localized: "实用工具"),
        "public.app-category.social-networking": String(localized: "社交"),
        "public.app-category.music": String(localized: "音乐"),
        "public.app-category.video": String(localized: "影音"),
        "public.app-category.entertainment": String(localized: "娱乐"),
        "public.app-category.photography": String(localized: "摄影"),
        "public.app-category.graphics-design": String(localized: "设计"),
        "public.app-category.education": String(localized: "教育"),
        "public.app-category.finance": String(localized: "财务"),
        "public.app-category.business": String(localized: "商务"),
        "public.app-category.news": String(localized: "新闻"),
        "public.app-category.reference": String(localized: "参考"),
        "public.app-category.lifestyle": String(localized: "生活"),
        "public.app-category.games": String(localized: "游戏"),
        "public.app-category.weather": String(localized: "天气"),
        "public.app-category.travel": String(localized: "旅行"),
        "public.app-category.healthcare-fitness": String(localized: "健康"),
        "public.app-category.medical": String(localized: "医疗"),
        "public.app-category.sports": String(localized: "运动"),
        "public.app-category.video-games": String(localized: "游戏"),
    ]
}

/// Everything needed to restore a layout elsewhere: pages, folders and per-app extras.
struct LayoutBackup: Codable {
    var app = "LaunchUS"
    var version = 1
    var pages: [[LayoutItem]]
    var meta: [String: AppMeta]
    /// Launch items that aren't apps; missing in older backups.
    var custom: [CustomItem]?
    /// The layout profile the pages belong to ("" is the default one).
    var profile: String?
    /// The other layout profiles; missing in older backups and in iCloud layouts.
    var profiles: [String: [[LayoutItem]]]?

    init(pages: [[LayoutItem]], meta: [String: AppMeta], custom: [CustomItem]? = nil) {
        self.pages = pages
        self.meta = meta
        self.custom = custom
    }

    /// A backup of everything: the pages on screen, launch items and every layout profile.
    init(pages: [[LayoutItem]], meta: [String: AppMeta], custom: [CustomItem], profiles file: LayoutProfiles.File) {
        self.init(pages: pages, meta: meta, custom: custom)
        profile = file.current
        profiles = file.saved.filter { $0.key != file.current }
    }
}

/// Options for rebuilding the layout from scratch ("整理布局 › 自定义规则").
struct LayoutRules: Equatable {
    enum Order: String, CaseIterable { case name, recentlyAdded, lastOpened, color }
    /// Where folders go among the apps.
    enum FolderPlacement: String, CaseIterable { case first, last, mixed }
    var keepFolders = true
    var groupByCategory = true
    /// Smallest category that gets its own folder.
    var minFolderSize = 3
    var systemAppsFolder = true
    var folderPlacement: FolderPlacement = .first
    var order: Order = .name
}

/// An icon's main colour, for arranging apps like a colour wheel.
struct IconColor: Equatable, Sendable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    /// Colourful icons by hue (red to violet), then the grey ones from light to dark.
    static func before(_ a: IconColor?, _ b: IconColor?) -> Bool? {
        let grey = 0.18
        guard let a, let b else { return a == nil && b == nil ? nil : a != nil }
        let aGrey = a.saturation < grey, bGrey = b.saturation < grey
        if aGrey != bGrey { return !aGrey }
        if aGrey {
            return abs(a.brightness - b.brightness) < 0.02 ? nil : a.brightness > b.brightness
        }
        // Twelve bands, so near-identical hues fall back to the name. Shifted half a band,
        // so the reds just below 1 join the ones just above 0.
        func band(_ hue: Double) -> Int { Int(((hue + 1.0 / 24).truncatingRemainder(dividingBy: 1)) * 12) }
        let aBand = band(a.hue), bBand = band(b.hue)
        return aBand == bBand ? nil : aBand < bBand
    }

    /// The average of the icon's opaque pixels, weighted toward the more saturated ones.
    static func of(_ image: CGImage) -> IconColor? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0, plain = 0.0, light = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.6 else { continue }
            let pr = Double(pixels[i]) / 255 / alpha, pg = Double(pixels[i + 1]) / 255 / alpha, pb = Double(pixels[i + 2]) / 255 / alpha
            let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0
            let weight = 0.05 + sat * sat
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
            plain += 1; light += maxC
        }
        guard total > 0, plain > 0 else { return nil }
        let color = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        return IconColor(hue: color.hueComponent, saturation: color.saturationComponent, brightness: light / plain)
    }
}

extension LayoutOps {
    static func arranged(_ installed: [AppItem], current: [[LayoutItem]], hidden: Set<String>,
                         rules: LayoutRules, perPage: Int, colors: [String: IconColor] = [:]) -> [[LayoutItem]] {
        let apps = installed.filter { !hidden.contains($0.id) }
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        var folders: [Folder] = []

        // Existing folders (smart ones always survive).
        for case .folder(var folder) in current.joined() {
            if folder.isSmart { folders.append(folder); continue }
            guard rules.keepFolders else { continue }
            folder.apps = folder.apps.filter { byID[$0] != nil && !used.contains($0) }
            guard folder.apps.count >= 2 else { continue }
            used.formUnion(folder.apps)
            folders.append(folder)
        }

        var remaining = apps.filter { !used.contains($0.id) }
        func byName(_ a: AppItem, _ b: AppItem) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }

        if rules.systemAppsFolder {
            let system = remaining.filter { $0.url.path.hasPrefix("/System/Applications/") }
            if system.count >= 2 {
                folders.append(Folder(name: String(localized: "系统"), apps: system.sorted(by: byName).map(\.id)))
                let ids = Set(system.map(\.id))
                remaining.removeAll { ids.contains($0.id) }
            }
        }
        if rules.groupByCategory {
            let groups = Dictionary(grouping: remaining) { AppCategoryName.tagName(for: $0.category) ?? "" }
            for (name, members) in groups where !name.isEmpty && members.count >= max(2, rules.minFolderSize) {
                folders.append(Folder(name: name, apps: members.sorted(by: byName).map(\.id)))
                let ids = Set(members.map(\.id))
                remaining.removeAll { ids.contains($0.id) }
            }
        }

        // What each item sorts by; a folder goes by its newest / most recently opened / first app.
        struct Key { var name: String; var added: Date; var opened: Date; var color: IconColor? }
        func key(_ name: String, _ ids: [String]) -> Key {
            let members = ids.compactMap { byID[$0] }
            return Key(name: name,
                       added: members.compactMap(\.addedDate).max() ?? .distantPast,
                       opened: members.compactMap(\.lastUsedDate).max() ?? .distantPast,
                       color: ids.first.flatMap { colors[$0] })
        }
        func before(_ a: Key, _ b: Key) -> Bool {
            switch rules.order {
            case .recentlyAdded where a.added != b.added: return a.added > b.added
            case .lastOpened where a.opened != b.opened: return a.opened > b.opened
            case .color: if let result = IconColor.before(a.color, b.color) { return result }
            default: break
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let folderItems = folders
            .map { (LayoutItem.folder($0), key($0.name, $0.apps)) }
            .sorted { before($0.1, $1.1) }
        let appItems = remaining
            .map { (LayoutItem.app($0.id), key($0.name, [$0.id])) }
            .sorted { before($0.1, $1.1) }
        let items: [LayoutItem] = switch rules.folderPlacement {
        case .first: folderItems.map(\.0) + appItems.map(\.0)
        case .last: appItems.map(\.0) + folderItems.map(\.0)
        case .mixed: (folderItems + appItems).sorted { before($0.1, $1.1) }.map(\.0)
        }
        return repack([items], perPage: perPage)
    }
}

extension LayoutOps {
    /// Every ordinary folder replaced by its apps, where the folder was. Smart folders stay.
    static func ungrouped(_ pages: [[LayoutItem]], perPage: Int) -> [[LayoutItem]] {
        let items = pages.joined().flatMap { item -> [LayoutItem] in
            guard case .folder(let folder) = item, !folder.isSmart else { return [item] }
            return folder.apps.map { .app($0) }
        }
        return repack([items], perPage: perPage)
    }

    /// All folders gathered at the start or the end, everything else keeping its order.
    static func foldersMoved(_ pages: [[LayoutItem]], toStart: Bool, perPage: Int) -> [[LayoutItem]] {
        let items = Array(pages.joined())
        let folders = items.filter { if case .folder = $0 { true } else { false } }
        let apps = items.filter { if case .app = $0 { true } else { false } }
        return repack([toStart ? folders + apps : apps + folders], perPage: perPage)
    }
}
