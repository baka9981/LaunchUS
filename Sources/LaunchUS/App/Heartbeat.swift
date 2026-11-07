import Foundation

/// The anonymous daily ping behind 「和开发者分享匿名使用信息」 (on by default, off in Settings ›
/// Advanced). Once a day it asks the download site for /ping with a random install number,
/// the LaunchUS and macOS versions, the chip, the system language, a few yes/no settings
/// (full screen, smart bar, iCloud sync, AI set up) and how many times the launcher opened
/// since the last ping, so the site can count how many Macs use LaunchUS and what they use.
/// No app names, searches, folder names, paths or anything that points to a person.
@MainActor
enum Heartbeat {
    private static let lastKey = "heartbeatLast"
    private static let opensKey = "heartbeatOpens"
    /// Whether the smart bar shows any tabs (the model knows; set by the app delegate).
    static var smartBarInUse: () -> Bool = { false }

    /// One more launcher open for the next ping.
    static func countOpen() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: opensKey) + 1, forKey: opensKey)
    }
    private static var timer: Timer?

    static func start() {
        guard timer == nil, endpoint != nil, ProcessInfo.processInfo.environment["LAUNCHUS_DEMO"] == nil else { return }
        // Macs stay on for weeks: look every hour rather than only at launch.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { sendIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { sendIfDue() }
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

    static func url(opens: Int) -> URL? {
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
            URLQueryItem(name: "mode", value: Settings.shared.displayMode == .fullScreen ? "full" : "window"),
            URLQueryItem(name: "bar", value: smartBarInUse() ? "1" : "0"),
            URLQueryItem(name: "icloud", value: Settings.shared.iCloudSync ? "1" : "0"),
            URLQueryItem(name: "ai", value: AIClient.isConfigured ? "1" : "0"),
            URLQueryItem(name: "opens", value: String(opens)),
        ]
        return parts.url
    }

    private static func sendIfDue() {
        guard Settings.shared.shareUsage else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        let opens = UserDefaults.standard.integer(forKey: opensKey)
        guard let url = url(opens: opens) else { return }
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
            }
        }.resume()
    }
}
