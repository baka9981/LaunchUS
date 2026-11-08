import AppKit
import Observation

/// `manifest.json` of a widget plugin. docs/WIDGETS.md is the full specification.
struct WidgetManifest: Decodable, Equatable {
    /// The specification version this app reads.
    static let spec = 1

    /// A plain string, or one per language: `{"en": "Weather", "zh-Hans": "天气"}`.
    struct Text: Decodable, Equatable {
        var values: [String: String]

        init(_ value: String) { values = ["": value] }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let plain = try? c.decode(String.self) {
                values = ["": plain]
            } else {
                values = try c.decode([String: String].self)
            }
        }

        /// The best match for the Mac's languages, then English, then any.
        func resolved(_ languages: [String] = Locale.preferredLanguages) -> String {
            if let plain = values[""] { return plain }
            for language in languages {
                if let exact = values[language] { return exact }
                // zh-Hans-CN → zh-Hans → zh
                var parts = language.split(separator: "-").map(String.init)
                while parts.count > 1 {
                    parts.removeLast()
                    if let match = values[parts.joined(separator: "-")] { return match }
                }
            }
            return values["en"] ?? values.sorted { $0.key < $1.key }.first?.value ?? ""
        }
    }

    enum Permission: String, Decodable {
        /// Loads from the internet; without it every http(s) and ws(s) request is blocked.
        case network
        /// `launchus.system()`: CPU, memory, disk, battery and network use.
        case system
    }

    var spec: Int
    var id: String
    var name: Text
    var description: Text?
    var version: String?
    var author: String?
    var homepage: URL?
    /// A picture in the plugin folder, for the gallery.
    var icon: String?
    /// An SF Symbol name, used when there's no icon.
    var symbol: String?
    var sizes: [WidgetItem.Size]
    /// The HTML page that draws the widget, relative to the plugin folder.
    var entry: String
    /// Seconds between `refresh` events while the launcher is open.
    var refresh: Double?
    var permissions: [Permission]
    /// What a click on the widget opens: a URL (https:, any app's scheme) …
    var open: URL?
    /// … or an app by bundle ID.
    var openApp: String?

    enum CodingKeys: String, CodingKey {
        case spec, id, name, description, version, author, homepage, icon, symbol, sizes, entry, refresh, permissions, open, openApp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spec = try c.decodeIfPresent(Int.self, forKey: .spec) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(Text.self, forKey: .name)
        description = try c.decodeIfPresent(Text.self, forKey: .description)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        homepage = try c.decodeIfPresent(URL.self, forKey: .homepage)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        // Sizes this version doesn't know are left out; with none left the plugin doesn't load.
        let sizes = (try c.decodeIfPresent([String].self, forKey: .sizes) ?? []).compactMap(WidgetItem.Size.init(rawValue:))
        self.sizes = WidgetItem.Size.allCases.filter(sizes.contains)
        entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? "index.html"
        refresh = try c.decodeIfPresent(Double.self, forKey: .refresh)
        // Unknown permissions are ignored, so a newer plugin still loads without them.
        permissions = (try c.decodeIfPresent([String].self, forKey: .permissions) ?? []).compactMap(Permission.init(rawValue:))
        open = try c.decodeIfPresent(URL.self, forKey: .open)
        openApp = try c.decodeIfPresent(String.self, forKey: .openApp)
    }

    enum Problem: Error, Equatable {
        case unreadable(String)
        case newerSpec(Int)
        case badID(String)
        case noSizes
        case missingEntry(String)

        var message: String {
            switch self {
            case .unreadable(let detail): String(localized: "manifest.json 读不出来：\(detail)")
            case .newerSpec(let spec): String(localized: "需要更新的 LaunchUS（规范版本 \(spec)）")
            case .badID(let id): String(localized: "ID “\(id)” 不合规范")
            case .noSizes: String(localized: "没有可用的尺寸")
            case .missingEntry(let entry): String(localized: "找不到页面文件 \(entry)")
            }
        }
    }

    /// Reverse-DNS, at least two parts, and not one of LaunchUS's own.
    static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !id.lowercased().hasPrefix("launchus."), id.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) } }
    }

    /// Reads and checks a plugin folder.
    static func load(_ folder: URL) -> Result<WidgetManifest, Problem> {
        let file = folder.appendingPathComponent("manifest.json")
        let manifest: WidgetManifest
        do {
            manifest = try JSONDecoder().decode(WidgetManifest.self, from: Data(contentsOf: file))
        } catch let DecodingError.keyNotFound(key, _) {
            return .failure(.unreadable(String(localized: "缺少 \(key.stringValue)")))
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            return .failure(.unreadable(context.codingPath.map(\.stringValue).joined(separator: ".")))
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        guard manifest.spec <= spec else { return .failure(.newerSpec(manifest.spec)) }
        guard isValidID(manifest.id) else { return .failure(.badID(manifest.id)) }
        guard !manifest.sizes.isEmpty else { return .failure(.noSizes) }
        guard let entry = manifest.file(manifest.entry, in: folder),
              FileManager.default.fileExists(atPath: entry.path) else { return .failure(.missingEntry(manifest.entry)) }
        return .success(manifest)
    }

    /// A file inside the plugin folder; nil for a path that leads out of it.
    func file(_ path: String, in folder: URL) -> URL? {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        return url.path.hasPrefix(root.path + "/") ? url : nil
    }
}

/// One kind of widget the gallery offers: built in, or a plugin from the plugins folder.
struct WidgetProvider: Identifiable, Equatable {
    enum Source: Equatable {
        case builtIn(BuiltInWidget)
        case plugin(folder: URL, manifest: WidgetManifest)
    }

    let id: String
    let source: Source

    var name: String {
        switch source {
        case .builtIn(let kind): kind.name
        case .plugin(_, let manifest): manifest.name.resolved()
        }
    }

    var summary: String {
        switch source {
        case .builtIn(let kind): kind.summary
        case .plugin(_, let manifest): manifest.description?.resolved() ?? ""
        }
    }

    var symbol: String {
        switch source {
        case .builtIn(let kind): kind.symbol
        case .plugin(_, let manifest): manifest.symbol ?? "puzzlepiece.extension"
        }
    }

    var category: BuiltInWidget.Category {
        switch source {
        case .builtIn(let kind): kind.category
        case .plugin: .plugin
        }
    }

    var icon: NSImage? {
        guard case .plugin(let folder, let manifest) = source, let path = manifest.icon,
              let url = manifest.file(path, in: folder) else { return nil }
        return NSImage(contentsOf: url)
    }

    var sizes: [WidgetItem.Size] {
        switch source {
        case .builtIn: WidgetItem.Size.allCases
        case .plugin(_, let manifest): manifest.sizes
        }
    }

    var isPlugin: Bool {
        if case .plugin = source { true } else { false }
    }

    /// The nearest size this widget comes in.
    func fit(_ size: WidgetItem.Size) -> WidgetItem.Size {
        if sizes.contains(size) { return size }
        let all = WidgetItem.Size.allCases
        let index = all.firstIndex(of: size) ?? 0
        return sizes.min { abs(all.firstIndex(of: $0)! - index) < abs(all.firstIndex(of: $1)! - index) } ?? .small
    }

    /// What clicking the widget opens, and the menu item's name for it.
    var openTarget: (title: String, url: URL)? {
        switch source {
        case .builtIn(let kind):
            return kind.openTarget
        case .plugin(_, let manifest):
            if let id = manifest.openApp, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return (String(localized: "打开 \(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))"), app)
            }
            // Only links that open something else: no file: or javascript: from a plugin.
            if let url = manifest.open, let scheme = url.scheme?.lowercased(), !["file", "javascript", "data"].contains(scheme) {
                return (String(localized: "打开链接"), url)
            }
            return nil
        }
    }
}

/// The built-in widgets and the plugins in `~/Library/Application Support/LaunchUS/Widgets`.
@MainActor @Observable
final class WidgetRegistry {
    static let shared = WidgetRegistry()

    static var pluginsFolder: URL {
        LayoutStore.directory.appendingPathComponent("Widgets", isDirectory: true)
    }

    static let pluginExtension = "launchuswidget"

    let builtIn: [WidgetProvider] = BuiltInWidget.allCases.map { WidgetProvider(id: $0.rawValue, source: .builtIn($0)) }
    private(set) var plugins: [WidgetProvider] = []
    /// Plugin folders that didn't load, with why, for the gallery.
    private(set) var problems: [(folder: String, problem: String)] = []
    /// Goes up on every rescan, so plugin pages load again after an edit.
    private(set) var generation = 0

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    private init() {
        reload()
        watch()
    }

    var all: [WidgetProvider] { builtIn + plugins }

    func provider(_ kind: String) -> WidgetProvider? {
        all.first { $0.id == kind }
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginsFolder, withIntermediateDirectories: true)
        let folders = ((try? fm.contentsOfDirectory(at: Self.pluginsFolder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == Self.pluginExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var found: [WidgetProvider] = []
        var problems: [(String, String)] = []
        for folder in folders {
            switch WidgetManifest.load(folder) {
            case .success(let manifest):
                if found.contains(where: { $0.id == manifest.id }) {
                    problems.append((folder.lastPathComponent, String(localized: "ID “\(manifest.id)” 和另一个插件重复")))
                } else {
                    found.append(WidgetProvider(id: manifest.id, source: .plugin(folder: folder, manifest: manifest)))
                }
            case .failure(let problem):
                problems.append((folder.lastPathComponent, problem.message))
            }
        }
        plugins = found
        self.problems = problems
        generation += 1
    }

    /// Copies a `.launchuswidget` folder in; one with the same ID is replaced.
    @discardableResult
    func install(_ source: URL) -> String? {
        guard source.pathExtension.lowercased() == Self.pluginExtension else {
            return String(localized: "只能安装 .launchuswidget 文件夹")
        }
        let manifest: WidgetManifest
        switch WidgetManifest.load(source) {
        case .success(let m): manifest = m
        case .failure(let problem): return problem.message
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginsFolder, withIntermediateDirectories: true)
        if case .plugin(let old, _)? = provider(manifest.id)?.source, old.standardizedFileURL != source.standardizedFileURL {
            try? fm.trashItem(at: old, resultingItemURL: nil)
        }
        let target = Self.pluginsFolder.appendingPathComponent(source.lastPathComponent)
        if target.standardizedFileURL != source.standardizedFileURL {
            try? fm.trashItem(at: target, resultingItemURL: nil)
            do { try fm.copyItem(at: source, to: target) } catch { return error.localizedDescription }
        }
        reload()
        return nil
    }

    /// Moves a plugin's folder to the Trash; widgets of it on the grid show as missing.
    func trash(_ provider: WidgetProvider) {
        guard case .plugin(let folder, _) = provider.source else { return }
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        reload()
    }

    /// Rescans when plugin folders come or go.
    private func watch() {
        let fd = open(Self.pluginsFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}
