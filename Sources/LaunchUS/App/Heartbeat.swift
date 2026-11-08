import Foundation

/// The anonymous daily ping behind 「和开发者分享匿名使用信息」 (on by default, off in Settings ›
/// Advanced). Once a day it asks the download site for /ping with a random install number,
/// the LaunchUS and macOS versions, the chip, the system language, a few yes/no settings
/// (full screen, smart bar, iCloud sync, AI set up) and how many times the launcher opened
/// since the last ping and by what (shortcut, pinch, hot corner…), so the site can count how
/// many Macs use LaunchUS and what they use. After a crash it also sends what macOS wrote down
/// about it (see `CrashReports`).
/// No app names, searches, folder names, paths or anything that points to a person.
@MainActor
enum Heartbeat {
    private static let lastKey = "heartbeatLast"
    private static let opensKey = "heartbeatOpens"
    private static let viaKey = "heartbeatVia"
    /// Whether the smart bar shows any tabs (the model knows; set by the app delegate).
    static var smartBarInUse: () -> Bool = { false }

    /// One more launcher open for the next ping.
    static func countOpen(via source: OpenSource) {
        guard Settings.shared.shareOpens else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: opensKey) + 1, forKey: opensKey)
        var via = defaults.dictionary(forKey: viaKey) as? [String: Int] ?? [:]
        via[source.rawValue, default: 0] += 1
        defaults.set(via, forKey: viaKey)
    }

    /// `hotKey:3,pinch:5`: the opens since the last ping, by what opened the launcher.
    static func viaParameter(_ via: [String: Int]) -> String {
        OpenSource.allCases.compactMap { s in via[s.rawValue].flatMap { $0 > 0 ? "\(s.rawValue):\($0)" : nil } }
            .joined(separator: ",")
    }
    private static var timer: Timer?

    static func start() {
        guard timer == nil, endpoint != nil, ProcessInfo.processInfo.environment["LAUNCHUS_DEMO"] == nil else { return }
        // Macs stay on for weeks: look every hour rather than only at launch.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { sendIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            sendIfDue()
            if Settings.shared.shareCrashes, let endpoint { CrashReports.sendNew(to: endpoint.deletingLastPathComponent()) }
        }
    }

    /// The download site the update feed lives on.
    private static var endpoint: URL? {
        guard let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)),
              feed.scheme == "https" else { return nil }
        return feed.deletingLastPathComponent().appendingPathComponent("ping")
    }

    /// A random number made once for this install; it says nothing about the Mac or its user.
    static var installID: String {
        let key = "installID"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static func url(opens: Int, via: [String: Int] = [:]) -> URL? {
        guard let endpoint, var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let chip = "arm64"
        #else
        let chip = "x86_64"
        #endif
        parts.queryItems = [
            URLQueryItem(name: "id", value: installID),
            URLQueryItem(name: "v", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"),
            URLQueryItem(name: "os", value: "\(os.majorVersion).\(os.minorVersion)"),
            URLQueryItem(name: "chip", value: chip),
            URLQueryItem(name: "lang", value: Locale.preferredLanguages.first ?? "?"),
        ]
        if Settings.shared.shareFeatures {
            parts.queryItems! += [
                URLQueryItem(name: "mode", value: Settings.shared.displayMode == .fullScreen ? "full" : "window"),
                URLQueryItem(name: "bar", value: smartBarInUse() ? "1" : "0"),
                URLQueryItem(name: "icloud", value: Settings.shared.iCloudSync ? "1" : "0"),
                URLQueryItem(name: "ai", value: AIClient.isConfigured ? "1" : "0"),
            ]
        }
        if Settings.shared.shareOpens {
            parts.queryItems! += [
                URLQueryItem(name: "opens", value: String(opens)),
                URLQueryItem(name: "via", value: viaParameter(via)),
            ]
        }
        return parts.url
    }

    private static func sendIfDue() {
        guard Settings.shared.shareUsage else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        let counted = Settings.shared.shareOpens
        let opens = counted ? UserDefaults.standard.integer(forKey: opensKey) : 0
        let via = counted ? UserDefaults.standard.dictionary(forKey: viaKey) as? [String: Int] ?? [:] : [:]
        guard let url = url(opens: opens, via: via) else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("LaunchUS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
                         forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, _ in
            guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return }
            DispatchQueue.main.async {
                let defaults = UserDefaults.standard
                defaults.set(Date().timeIntervalSince1970, forKey: lastKey)
                // Opens counted while the ping was on its way stay for the next one.
                defaults.set(max(0, defaults.integer(forKey: opensKey) - opens), forKey: opensKey)
                var left = defaults.dictionary(forKey: viaKey) as? [String: Int] ?? [:]
                for (key, n) in via { left[key] = max(0, (left[key] ?? 0) - n) }
                defaults.set(left.filter { $0.value > 0 }, forKey: viaKey)
            }
        }.resume()
    }
}

/// What opened the launcher, counted for the ping.
enum OpenSource: String, CaseIterable, Sendable {
    case hotKey, pinch, hotCorner, f4, appIcon, menuBar, link, other
}

/// Crashes, from the reports macOS writes to ~/Library/Logs/DiagnosticReports. Sent once each,
/// at the next launch: the version, macOS, the kind of crash, the system's one-line reason and
/// the names of the functions it happened in. Nothing about the Mac's files or its user.
@MainActor
enum CrashReports {
    private static let sentKey = "crashReportsSent"

    static func sendNew(to base: URL) {
        let defaults = UserDefaults.standard
        let since = defaults.double(forKey: sentKey)
        let cutoff = max(since, Date().timeIntervalSince1970 - 14 * 86400)
        let reports = recent(after: cutoff)
        guard !reports.isEmpty else { return }
        defaults.set(reports.map(\.date).max()!, forKey: sentKey)
        for report in reports.suffix(3) {
            guard let url = url(for: report, base: base) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("LaunchUS/\(report.version)", forHTTPHeaderField: "User-Agent")
            URLSession(configuration: .ephemeral).dataTask(with: request).resume()
        }
    }

    struct Report: Equatable {
        var date: TimeInterval
        var version: String
        var os: String
        var type: String
        var signal: String
        var reason: String
        var frames: [String]
    }

    static func url(for report: Report, base: URL) -> URL? {
        guard var parts = URLComponents(url: base.appendingPathComponent("crash"), resolvingAgainstBaseURL: false) else { return nil }
        var frames = ""
        for frame in report.frames where frames.count + frame.count < 900 {
            frames += (frames.isEmpty ? "" : "|") + frame
        }
        parts.queryItems = [
            URLQueryItem(name: "id", value: Heartbeat.installID),
            URLQueryItem(name: "v", value: report.version),
            URLQueryItem(name: "os", value: report.os),
            URLQueryItem(name: "t", value: String(Int(report.date))),
            URLQueryItem(name: "type", value: report.type),
            URLQueryItem(name: "sig", value: report.signal),
            URLQueryItem(name: "why", value: String(report.reason.prefix(160))),
            URLQueryItem(name: "at", value: frames),
        ]
        return parts.url
    }

    private static func recent(after cutoff: TimeInterval) -> [Report] {
        let fm = FileManager.default
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { file -> Report? in
            guard file.lastPathComponent.hasPrefix("LaunchUS"), file.pathExtension == "ips",
                  let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date.timeIntervalSince1970 > cutoff,
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  var report = parse(text) else { return nil }
            report.date = date.timeIntervalSince1970
            return report
        }.sorted { $0.date < $1.date }
    }

    /// An .ips file: a one-line JSON header, then the report as JSON.
    static func parse(_ text: String) -> Report? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any],
              header["app_name"] as? String == "LaunchUS",
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any]
        else { return nil }
        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]
        // The message the crash left, e.g. Swift's "Fatal error: Index out of range".
        let asi = (body["asi"] as? [String: [String]])?.values.flatMap { $0 }.first
        let reason = asi ?? termination["indicator"] as? String ?? ""
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? 0
        let thread = threads.indices.contains(faulting) ? threads[faulting] : threads.first(where: { $0["triggered"] as? Bool == true })
        let frames = (thread?["frames"] as? [[String: Any]] ?? []).prefix(14).map { frame -> String in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : "?"
            let symbol = frame["symbol"] as? String ?? "0x" + String(frame["imageOffset"] as? Int ?? 0, radix: 16)
            return String("\(image) \(symbol)".prefix(120))
        }
        let os = (header["os_version"] as? String ?? "").replacingOccurrences(of: "macOS ", with: "")
        return Report(date: 0,
                      version: header["app_version"] as? String ?? "?",
                      os: String(os.split(separator: " ").first ?? ""),
                      type: exception["type"] as? String ?? "?",
                      signal: exception["signal"] as? String ?? "",
                      reason: reason.replacingOccurrences(of: "\n", with: " "),
                      frames: frames)
    }
}
