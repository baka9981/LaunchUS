import AppKit

/// Finds an app's files outside its bundle (caches, preferences, containers…) so
/// uninstalling can move them to the Trash together with the app.
enum Uninstaller {
    struct Group: Identifiable {
        let id: String
        let title: String
        var files: [File]
        var size: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    struct File: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let size: Int64
        /// Some of it couldn't be read (another app's protected data): the size is too low,
        /// and moving it to the Trash needs Full Disk Access.
        var restricted = false
    }

    /// Group titles in display order, matched against these folders under ~/Library.
    /// Each folder entry matches names equal to the bundle ID (or app name where noted),
    /// or starting with "<bundle ID>." (extensions, helpers).
    private static let rules: [(id: String, title: String, folders: [String], byName: Bool)] = [
        ("support", String(localized: "支持文件"), ["Application Support"], true),
        ("caches", String(localized: "缓存"), ["Caches", "WebKit"], true),
        ("prefs", String(localized: "偏好设置"), ["Preferences", "Preferences/ByHost"], false),
        ("http", String(localized: "HTTP 存储"), ["HTTPStorages", "Cookies"], false),
        ("sandbox", String(localized: "沙盒"), ["Containers"], false),
        ("groups", String(localized: "容器"), ["Group Containers"], false),
        ("scripts", String(localized: "应用脚本"), ["Application Scripts"], false),
        ("state", String(localized: "已保存状态"), ["Saved Application State"], false),
        ("logs", String(localized: "日志"), ["Logs"], true),
        ("agents", String(localized: "启动项"), ["LaunchAgents"], false),
    ]

    /// Runs off the main thread: walking containers can take a moment.
    static func scan(_ app: AppItem) async -> [Group] {
        await Task.detached(priority: .userInitiated) { scanSync(app) }.value
    }

    private static func scanSync(_ app: AppItem) -> [Group] {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var groups = [Group(id: "app", title: String(localized: "应用文件"), files: [file(app.url)])]
        guard let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty else { return groups }
        let bundleName = app.url.deletingPathExtension().lastPathComponent.lowercased()
        var seen = Set<String>()

        for rule in rules {
            var files: [File] = []
            for folder in rule.folders {
                let dir = library.appendingPathComponent(folder)
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names where matches(name.lowercased(), bundleID: bundleID,
                                                appName: rule.byName ? bundleName : nil) {
                    let url = dir.appendingPathComponent(name)
                    guard seen.insert(url.path).inserted else { continue }
                    files.append(file(url))
                }
            }
            if !files.isEmpty {
                groups.append(Group(id: rule.id, title: rule.title, files: files.sorted { $0.size > $1.size }))
            }
        }
        return groups
    }

    static func matches(_ name: String, bundleID: String, appName: String?) -> Bool {
        // Strip the usual suffixes: .plist, .savedState, .binarycookies, ByHost's ".<UUID>.plist".
        var stem = name
        for ext in [".plist", ".savedstate", ".binarycookies"] where stem.hasSuffix(ext) {
            stem = String(stem.dropLast(ext.count))
        }
        if stem == bundleID || stem.hasPrefix(bundleID + ".") { return true }
        // Group containers and app scripts are named "<TEAMID>.<bundle ID>…" or "group.<bundle ID>…".
        if let dot = stem.firstIndex(of: "."), stem[..<dot] == "group" || stem.distance(from: stem.startIndex, to: dot) == 10 {
            let rest = stem[stem.index(after: dot)...]
            if rest == bundleID || rest.hasPrefix(bundleID + ".") { return true }
        }
        if let appName, appName.count >= 3, stem == appName { return true }
        return false
    }

    /// Allocated size on disk, like Finder's "on disk" figure.
    private static func file(_ url: URL) -> File {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true else { return File(url: url, size: Int64(values?.totalFileAllocatedSize ?? 0)) }
        var total: Int64 = 0
        var denied = false
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                    errorHandler: { _, _ in denied = true; return true })
        while let item = walker?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return File(url: url, size: total, restricted: denied)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Quits the app if it's running, then moves the chosen files to the Trash.
    /// Returns the files that couldn't be moved.
    static func trash(_ urls: [URL], bundleID: String?) async -> [URL] {
        if let bundleID {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            running.forEach { $0.terminate() }
            for _ in 0..<30 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        var failed: [URL] = []
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failed.append(url) }
        }
        return failed
    }
}
