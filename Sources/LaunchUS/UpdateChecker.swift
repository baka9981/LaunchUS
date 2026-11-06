import AppKit

/// A newer version of an installed app.
struct AppUpdate: Equatable {
    enum Source: Equatable { case sparkle, appStore }
    let version: String
    let source: Source
    /// The App Store page; Sparkle apps update themselves once opened.
    var page: URL?
}

/// Asks each app's own update source whether there's a newer version: the update feed of
/// apps that use Sparkle, or the App Store for apps installed from it. Read only: updating
/// is left to the app or the App Store. Runs only when asked to.
enum UpdateChecker {
    /// What's needed to check one app, read from its bundle.
    struct Target: Sendable {
        let id: String
        let bundleID: String?
        let shortVersion: String?
        let build: String?
        var feed: URL?
        var appStore = false
    }

    nonisolated static func target(for app: AppItem) -> Target? {
        guard app.custom == nil,
              let info = NSDictionary(contentsOf: app.url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        var target = Target(id: app.id, bundleID: app.bundleID,
                            shortVersion: info["CFBundleShortVersionString"] as? String,
                            build: info["CFBundleVersion"] as? String)
        if let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.scheme == "https" {
            target.feed = feed
        }
        target.appStore = FileManager.default.fileExists(atPath: app.url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        return target.feed != nil || (target.appStore && target.bundleID != nil) ? target : nil
    }

    /// Checks a few at a time; `progress` gets each result as it comes.
    static func check(_ targets: [Target], progress: @escaping @MainActor (String, AppUpdate?) -> Void) async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        await withTaskGroup(of: (String, AppUpdate?).self) { group in
            var pending = targets[...]
            func next() {
                guard let target = pending.popFirst() else { return }
                group.addTask { (target.id, await check(target, session: session)) }
            }
            for _ in 0..<6 { next() }
            for await (id, update) in group {
                await progress(id, update)
                next()
            }
        }
        session.invalidateAndCancel()
    }

    nonisolated static func check(_ target: Target, session: URLSession) async -> AppUpdate? {
        if target.appStore, let bundleID = target.bundleID {
            return await appStore(bundleID, installed: target.shortVersion, session: session)
        }
        guard let feed = target.feed,
              let (data, response) = try? await session.data(from: feed),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = latest(inAppcast: data) else { return nil }
        let installed = latest.build != nil ? target.build : target.shortVersion
        guard let installed, compare(latest.build ?? latest.short ?? "", installed) == .orderedDescending else { return nil }
        return AppUpdate(version: latest.short ?? latest.build ?? "", source: .sparkle)
    }

    nonisolated private static func appStore(_ bundleID: String, installed: String?, session: URLSession) async -> AppUpdate? {
        var parts = URLComponents(string: "https://itunes.apple.com/lookup")!
        parts.queryItems = [URLQueryItem(name: "bundleId", value: bundleID),
                            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US")]
        guard let installed, let url = parts.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (json["results"] as? [[String: Any]])?.first,
              let version = result["version"] as? String,
              compare(version, installed) == .orderedDescending else { return nil }
        // Open the page in the App Store app rather than the browser.
        let page = (result["trackViewUrl"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "https://", with: "macappstore://")) }
        return AppUpdate(version: version, source: .appStore, page: page)
    }

    /// The newest release in a Sparkle appcast, leaving out beta channels and releases this
    /// macOS is too old for. `build` is `sparkle:version`, compared with CFBundleVersion.
    nonisolated static func latest(inAppcast data: Data,
                                   system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion)
        -> (build: String?, short: String?)? {
        let reader = AppcastReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let os = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        let usable = reader.items.filter { item in
            item.channel == nil && (item.build ?? item.short) != nil
                && (item.minimumSystem.map { compare($0, os) != .orderedDescending } ?? true)
        }
        let best = usable.max { compare($0.build ?? $0.short!, $1.build ?? $1.short!) == .orderedAscending }
        return best.map { ($0.build, $0.short) }
    }

    /// Numbers compared one by one: "1.10" is newer than "1.9", "2.0" equals "2".
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func numbers(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).map { Int($0.prefix(18)) ?? 0 }
        }
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

private final class AppcastReader: NSObject, XMLParserDelegate {
    struct Item {
        var build: String?
        var short: String?
        var channel: String?
        var minimumSystem: String?
    }

    var items: [Item] = []
    private var current: Item?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = Item() }
        if name == "enclosure", var item = current {
            item.build = item.build ?? attributes["sparkle:version"]
            item.short = item.short ?? attributes["sparkle:shortVersionString"]
            current = item
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item": if let current { items.append(current) }; current = nil
        case "sparkle:version" where !value.isEmpty: current?.build = value
        case "sparkle:shortVersionString" where !value.isEmpty: current?.short = value
        case "sparkle:channel" where !value.isEmpty: current?.channel = value
        case "sparkle:minimumSystemVersion" where !value.isEmpty: current?.minimumSystem = value
        default: break
        }
        text = ""
    }
}
