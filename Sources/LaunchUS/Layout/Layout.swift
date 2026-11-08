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
    /// An empty cell, kept when icons can be placed anywhere.
    case gap
    /// A widget; it sits in its top-left cell and covers the rest of its block.
    case widget(WidgetItem)
    /// A cell under a widget (its ID), or one left empty because the next widget didn't fit
    /// there (an empty ID). Made by `LayoutOps.pack` and never placed by itself.
    case cover(String)

    var id: String {
        switch self {
        case .app(let id): "app:" + id
        case .folder(let folder): "folder:" + folder.id
        case .gap: "gap"
        case .widget(let widget): "widget:" + widget.id
        case .cover(let owner): "cover:" + owner
        }
    }

    var appIDs: [String] {
        switch self {
        case .app(let id): [id]
        case .folder(let folder): folder.apps
        case .gap, .widget, .cover: []
        }
    }

    /// Nothing is drawn there and it takes no clicks: an empty cell or one under a widget.
    var isGap: Bool {
        switch self {
        case .gap, .cover: true
        default: false
        }
    }

    var isWidget: Bool {
        if case .widget = self { return true }
        return false
    }

    var isCover: Bool {
        if case .cover = self { return true }
        return false
    }

    // Stored in the same shape the compiler used to synthesise, `{"app":{"_0":…}}`. An empty
    // cell is written as an app with no ID, which older versions simply drop as uninstalled.
    // A widget is written as an empty cell with the widget beside it, so older versions keep
    // reading the layout; a covered cell is written as an empty one (`pack` takes it back).
    private enum CodingKeys: String, CodingKey { case app, folder, widget }
    private enum ValueKeys: String, CodingKey { case _0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let widget = try? c.decode(WidgetItem.self, forKey: .widget) {
            self = .widget(widget)
        } else if c.contains(.app) {
            let id = try c.nestedContainer(keyedBy: ValueKeys.self, forKey: .app).decode(String.self, forKey: ._0)
            self = id.isEmpty ? .gap : .app(id)
        } else {
            self = .folder(try c.nestedContainer(keyedBy: ValueKeys.self, forKey: .folder).decode(Folder.self, forKey: ._0))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let id):
            var v = c.nestedContainer(keyedBy: ValueKeys.self, forKey: .app)
            try v.encode(id, forKey: ._0)
        case .gap, .cover:
            var v = c.nestedContainer(keyedBy: ValueKeys.self, forKey: .app)
            try v.encode("", forKey: ._0)
        case .widget(let widget):
            var v = c.nestedContainer(keyedBy: ValueKeys.self, forKey: .app)
            try v.encode("", forKey: ._0)
            try c.encode(widget, forKey: .widget)
        case .folder(let folder):
            var v = c.nestedContainer(keyedBy: ValueKeys.self, forKey: .folder)
            try v.encode(folder, forKey: ._0)
        }
    }

    /// Columns and rows it takes on a grid of that shape.
    func span(columns: Int, rows: Int) -> (width: Int, height: Int) {
        if case .widget(let widget) = self { return widget.size.span(columns: columns, rows: rows) }
        return (1, 1)
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
    /// Global shortcut that opens the app from anywhere (`HotKeyGroup.apps`).
    var shortcut: HotKeySpec?
    /// Category tab the user moved the app to (an `AppCategoryName.Group`), instead of the one its developer declares.
    var group: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        shortcut = try c.decodeIfPresent(HotKeySpec.self, forKey: .shortcut)
        group = try c.decodeIfPresent(String.self, forKey: .group)
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
    /// Smart folders that live only in the smart bar.
    static var barFoldersURL: URL { directory.appendingPathComponent("bar-folders.json") }

    static func loadBarFolders() -> [Folder] {
        guard let data = try? Data(contentsOf: barFoldersURL) else { return [] }
        return (try? JSONDecoder().decode([Folder].self, from: data)) ?? []
    }

    static func save(barFolders: [Folder]) {
        write(barFolders, to: barFoldersURL)
        AutoBackup.schedule()
        ICloudSync.localChanged()
    }

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
    /// so none exceeds `perPage`. Empty pages are removed. With `free` placement a removed
    /// app leaves an empty cell behind, so the icons after it stay where they were put.
    static func reconcile(_ pages: [[LayoutItem]], installed: [AppItem], hidden: Set<String>, perPage: Int,
                          columns: Int? = nil, free: Bool = false) -> [[LayoutItem]] {
        let valid = Set(installed.map(\.id)).subtracting(hidden)
        var placed = Set<String>()

        var result: [[LayoutItem]] = pages.map { page in
            page.compactMap { item in
                switch item {
                case .app(let id):
                    guard valid.contains(id), placed.insert(id).inserted else { return free ? .gap : nil }
                    return item
                case .folder(var folder):
                    if folder.isSmart { return item }
                    folder.apps = folder.apps.filter { valid.contains($0) && placed.insert($0).inserted }
                    return folder.apps.isEmpty ? (free ? .gap : nil) : .folder(folder)
                case .gap:
                    return free ? item : nil
                case .widget:
                    return placed.insert(item.id).inserted ? item : nil
                case .cover:
                    return free ? item : nil
                }
            }
        }

        let newApps = installed.filter { valid.contains($0.id) && !placed.contains($0.id) }
        if !newApps.isEmpty {
            if result.isEmpty { result = [[]] }
            trimTrailingGaps(&result[result.count - 1])
            result[result.count - 1].append(contentsOf: newApps.map { .app($0.id) })
        }
        return repack(result, perPage: perPage, columns: columns, free: free)
    }

    /// Pushes overflow forward page by page and removes empty pages. Lined-up placement also
    /// closes every empty cell; free placement keeps them, giving up the last ones on a page
    /// before pushing an icon to the next page. Every page comes out packed (`pack`), so an
    /// item's index is its cell even with widgets on the page.
    /// `columns` defaults to the whole page in one row.
    static func repack(_ pages: [[LayoutItem]], perPage: Int, columns: Int? = nil, free: Bool = false,
                       keepEmptyPages: Bool = false) -> [[LayoutItem]] {
        let columns = max(1, min(columns ?? perPage, perPage))
        let rows = max(1, perPage / columns)
        var result = free ? pages : pages.map { $0.filter { !$0.isGap } }
        var i = 0
        while i < result.count {
            if free { trimTrailingGaps(&result[i]) }
            var packed = pack(result[i], columns: columns, rows: rows, free: free)
            // Free placement gives up empty cells (from the end) before pushing icons on.
            // A widget already counts empty cells as room, so only icons are worth it.
            while free, packed.overflow.contains(where: { !$0.isWidget }), let gap = result[i].lastIndex(where: { if case .gap = $0 { true } else { false } }) {
                result[i].remove(at: gap)
                packed = pack(result[i], columns: columns, rows: rows, free: free)
            }
            result[i] = packed.page
            if !packed.overflow.isEmpty {
                if i + 1 < result.count {
                    result[i + 1].insert(contentsOf: packed.overflow, at: 0)
                } else {
                    result.append(packed.overflow)
                }
            }
            i += 1
        }
        if !keepEmptyPages { result.removeAll { $0.allSatisfy(\.isGap) } }
        return result
    }

    /// Lays a page's items into its cells in order, like a phone's home screen: each takes the
    /// first free cell (a widget the first block it fits in). The result has one item per
    /// cell, with `.cover` under widgets and in cells nothing could use, so an item's index is
    /// its cell. What doesn't fit within `rows`, and everything after it, is the overflow.
    /// Free placement keeps empty cells where they are; an empty cell a widget or a pushed icon
    /// now sits on is given up, so the icons after it stay put.
    static func pack(_ items: [LayoutItem], columns: Int, rows: Int?, free: Bool) -> (page: [LayoutItem], overflow: [LayoutItem]) {
        let widgets = Set(items.compactMap { item -> String? in
            if case .widget(let w) = item { return w.id }
            return nil
        })
        var cells: [LayoutItem?] = []
        var overflow: [LayoutItem] = []
        func isFree(_ k: Int) -> Bool { k >= cells.count || cells[k] == nil }
        func put(_ item: LayoutItem, at k: Int) {
            while cells.count <= k { cells.append(nil) }
            cells[k] = item
        }
        var firstFree = 0
        for (index, original) in items.enumerated() {
            var item = original
            if case .cover(let owner) = item {
                // A widget that's gone leaves empty cells behind in free placement.
                guard free, !owner.isEmpty, !widgets.contains(owner) else { continue }
                item = .gap
            }
            if !free, case .gap = item { continue }
            // Lined-up: what comes after an item that didn't fit follows it to the next page.
            if !overflow.isEmpty, !free {
                if case .gap = item { continue }
                overflow.append(item)
                continue
            }
            while !isFree(firstFree) { firstFree += 1 }
            let (w, h) = item.span(columns: columns, rows: rows ?? Int.max)
            var start = firstFree
            if w > 1 || h > 1 {
                while true {
                    let c = start % columns
                    if c + w <= columns,
                       (0..<h).allSatisfy({ dy in (0..<w).allSatisfy { dx in isFree(start + dy * columns + dx) } }) { break }
                    start += 1
                }
            }
            if case .gap = item, start > index { continue }
            if let rows, start / columns + h > rows {
                if case .gap = item { continue }
                // Free placement: a widget past the bottom takes the nearest block that fits
                // (empty cells included), or goes on alone; nothing else moves with it.
                if free, w > 1 || h > 1 {
                    if let near = nearestBlock(to: start, w: w, h: h, columns: columns, rows: rows, cells: cells) {
                        start = near
                    } else {
                        overflow.append(item)
                        continue
                    }
                } else {
                    overflow.append(item)
                    continue
                }
            }
            put(item, at: start)
            if case .widget(let widget) = item {
                for dy in 0..<h {
                    for dx in 0..<w where dx > 0 || dy > 0 { put(.cover(widget.id), at: start + dy * columns + dx) }
                }
            }
        }
        var page = cells.map { $0 ?? .cover("") }
        // Nothing to keep after the last item (a widget's own cells stay).
        while let last = page.last, last == .cover("") || last == .gap { page.removeLast() }
        return (page, overflow)
    }

    /// The free w × h block within `rows` closest to `start` (rows first, then columns).
    /// Empty cells count as free.
    static func nearestBlock(to start: Int, w: Int, h: Int, columns: Int, rows: Int, cells: [LayoutItem?]) -> Int? {
        func open(_ k: Int) -> Bool {
            guard k < cells.count, let item = cells[k] else { return true }
            return item == .gap
        }
        let row = start / columns, col = start % columns
        var best: (score: Int, start: Int)?
        for r in 0...max(0, rows - h) {
            for c in 0...max(0, columns - w) {
                let s = r * columns + c
                guard (0..<h).allSatisfy({ dy in (0..<w).allSatisfy { dx in open(s + dy * columns + dx) } }) else { continue }
                let score = abs(r - row) * columns * 2 + abs(c - col)
                if best == nil || score < best!.score { best = (score, s) }
            }
        }
        return best?.start
    }

    static func trimTrailingGaps(_ page: inout [LayoutItem]) {
        while let last = page.last, last == .gap || last == .cover("") { page.removeLast() }
    }

    /// Free placement after the grid changed shape: every icon keeps its row and column. Ones
    /// that no longer fit take the page's first empty cells, or move on to the next page.
    static func regrid(_ pages: [[LayoutItem]], fromColumns: Int, toColumns: Int, rows: Int) -> [[LayoutItem]] {
        guard fromColumns > 0, toColumns > 0 else { return pages }
        let perPage = toColumns * rows
        var result: [[LayoutItem]] = []
        var carried: [LayoutItem] = []
        for page in pages {
            var cells = [LayoutItem](repeating: .gap, count: perPage)
            var displaced = carried
            carried = []
            for (i, item) in page.enumerated() where !item.isGap {
                let r = i / fromColumns, c = i % fromColumns
                if c < toColumns, r < rows { cells[r * toColumns + c] = item } else { displaced.append(item) }
            }
            for item in displaced {
                if let free = cells.firstIndex(where: \.isGap) { cells[free] = item } else { carried.append(item) }
            }
            result.append(cells)
        }
        while !carried.isEmpty {
            result.append(Array(carried.prefix(perPage)))
            carried.removeFirst(min(perPage, carried.count))
        }
        return repack(result, perPage: perPage, free: true)
    }

    /// After the grid grows: each page that was full at the old size takes items from the start
    /// of the following pages until it's full again. Pages left short on purpose stay as they are.
    static func fill(_ pages: [[LayoutItem]], wasPerPage: Int, perPage: Int) -> [[LayoutItem]] {
        guard perPage > wasPerPage, wasPerPage > 0 else { return pages }
        var result = pages
        // Judged before any page gives items away to the one before it.
        let wasFull = pages.map { $0.count >= wasPerPage }
        for i in result.indices where wasFull[i] {
            var next = i + 1
            while result[i].count < perPage, next < result.count {
                let take = min(perPage - result[i].count, result[next].count)
                result[i].append(contentsOf: result[next].prefix(take))
                result[next].removeFirst(take)
                if result[next].isEmpty { next += 1 }
            }
        }
        result.removeAll { $0.isEmpty }
        return result
    }

    /// Lined-up pages that had no room for the first item of the page after them, so that
    /// page break most likely came from overflow, not from the user.
    static func fullPages(_ pages: [[LayoutItem]], columns: Int, rows: Int) -> [Bool] {
        pages.indices.map { i in
            guard i + 1 < pages.count, let first = pages[i + 1].first(where: { !$0.isGap }) else { return false }
            return !pack(pages[i] + [first], columns: columns, rows: rows, free: false).overflow.isEmpty
        }
    }

    /// After something on a page got smaller or went away (a widget), the pages that were full
    /// (`fullPages`, judged before) take back what was pushed on to the page after them, as
    /// much as fits again, so adding a widget and removing it leaves the apps where they were.
    static func refill(_ pages: [[LayoutItem]], wasFull: [Bool], columns: Int, rows: Int) -> [[LayoutItem]] {
        var result = pages.map { $0.filter { !$0.isGap } }
        func full(_ i: Int) -> Bool { i < wasFull.count && wasFull[i] }
        for i in result.indices where full(i) {
            var next = i + 1
            while next < result.count {
                guard let first = result[next].first else {
                    // Emptied: go on to the page after it only if that break was overflow too.
                    guard full(next) else { break }
                    next += 1
                    continue
                }
                guard pack(result[i] + [first], columns: columns, rows: rows, free: false).overflow.isEmpty else { break }
                result[i].append(result[next].removeFirst())
            }
        }
        return repack(result, perPage: columns * rows, columns: columns)
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
    /// Smart folders shown only in the smart bar; missing in older backups.
    var barFolders: [Folder]?
    /// Each profile's own settings and hidden apps (`ProfileSettings`); missing in older backups.
    var settings: [String: [String: String]]?

    init(pages: [[LayoutItem]], meta: [String: AppMeta], custom: [CustomItem]? = nil, barFolders: [Folder]? = nil) {
        self.pages = pages
        self.meta = meta
        self.custom = custom
        self.barFolders = barFolders
    }

    /// A backup of everything: the pages on screen, launch items, bar-only smart folders and every layout profile.
    init(pages: [[LayoutItem]], meta: [String: AppMeta], custom: [CustomItem], barFolders: [Folder] = [], profiles file: LayoutProfiles.File) {
        self.init(pages: pages, meta: meta, custom: custom, barFolders: barFolders)
        profile = file.current
        profiles = file.saved.filter { $0.key != file.current }
    }

    /// One layout profile in a backup file.
    struct Profile: Identifiable {
        var name: String
        var pages: [[LayoutItem]]
        /// Its settings and hidden apps; nil in older backups.
        var settings: [String: String]?
        var id: String { name }
    }

    /// The profiles in the file: the one `pages` belongs to first, then the others by name.
    @MainActor var allProfiles: [Profile] {
        let first = profile ?? ""
        var firstSettings = settings?[first]
        if firstSettings == nil || ProfileSettings.hiddenApps(in: firstSettings) == nil {
            // Older backups keep its hidden apps in the apps' extras.
            var values = firstSettings ?? [:]
            ProfileSettings.setHiddenApps(Set(meta.filter { $0.value.hidden }.map(\.key)), in: &values)
            firstSettings = values
        }
        let others = (profiles ?? [:]).filter { $0.key != first }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { Profile(name: $0.key, pages: $0.value, settings: settings?[$0.key]) }
        return [Profile(name: first, pages: pages, settings: firstSettings)] + others
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
        // Widgets stay at the top of the first page.
        let widgets = current.joined().filter { if case .widget = $0 { true } else { false } }
        return repack([widgets + items], perPage: perPage)
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
        let widgets = items.filter { if case .widget = $0 { true } else { false } }
        return repack([widgets + (toStart ? folders + apps : apps + folders)], perPage: perPage)
    }
}
