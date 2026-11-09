import AppKit
import Observation
import os

/// What the App manager knows about the installed apps: version and chip (read each time it
/// opens, quickly), size (slow, kept until the app changes) and found updates.
@MainActor @Observable
final class AppInventory {
    static let shared = AppInventory()

    private(set) var infos: [String: AppInfo] = [:]
    private(set) var sizes: [String: Int64] = [:]
    private(set) var updates: [String: AppUpdate] = [:]
    /// While checking for updates: how many are done out of how many.
    private(set) var checking: (done: Int, total: Int)?
    private(set) var lastChecked: Date?
    /// Apps that could be checked, after the last check.
    private(set) var checkable = 0
    /// Duplicate apps and leftovers of removed ones; nil until scanned.
    private(set) var duplicates: [DuplicateApp]?
    private(set) var leftovers: [Leftover]?
    private(set) var cleaning = false
    @ObservationIgnored private var known: [AppItem] = []

    /// Sizes are kept per app and version, so an updated app is measured again.
    @ObservationIgnored private var sizeKeys: [String: String] = [:]
    @ObservationIgnored private var scanning = false

    func scan(_ apps: [AppItem]) {
        guard !scanning else { return }
        scanning = true
        let apps = apps.filter { $0.custom == nil }
        known = apps
        Task {
            let read = await Task.detached(priority: .userInitiated) {
                Dictionary(apps.map { ($0.id, AppInfo.read($0.url)) }, uniquingKeysWith: { a, _ in a })
            }.value
            infos = read
            let missing = apps.filter { sizeKeys[$0.id] != Self.sizeKey($0, read[$0.id]) }
            for chunk in stride(from: 0, to: missing.count, by: 8).map({ Array(missing[$0..<min($0 + 8, missing.count)]) }) {
                let measured = await Task.detached(priority: .utility) {
                    chunk.map { ($0.id, Uninstaller.file($0.url).size) }
                }.value
                for (id, size) in measured { sizes[id] = size }
                for app in chunk { sizeKeys[app.id] = Self.sizeKey(app, read[app.id]) }
            }
            scanning = false
        }
    }

    func scanCleanup(force: Bool = false) {
        guard !cleaning, force || duplicates == nil else { return }
        cleaning = true
        let apps = known
        let installed = Set(apps.compactMap { $0.bundleID?.lowercased() })
        Task {
            let result = await Task.detached(priority: .utility) {
                (AppCleanup.duplicates(of: apps), AppCleanup.leftovers(installed: installed))
            }.value
            duplicates = result.0
            leftovers = result.1
            cleaning = false
        }
    }

    nonisolated static var dryRun: Bool { ProcessInfo.processInfo.environment["LAUNCHUS_SNAPSHOT"] != nil }

    /// Moves files to the Trash, then scans again. Returns how many couldn't be moved.
    @discardableResult
    func trash(_ urls: [URL]) async -> Int {
        // Debug snapshot runs show the real UI on real data: never let a stray click there delete anything.
        if Self.dryRun {
            NSLog("LaunchUS dry run: would trash \(urls.count) items")
            return 0
        }
        let failed = await Uninstaller.trash(urls, bundleID: nil)
        cleaning = false
        scanCleanup(force: true)
        return failed.count
    }

    /// Casks being upgraded, by app ID.
    private(set) var upgrading: Set<String> = []

    /// Runs `brew upgrade --cask`; on success the update is gone from the list.
    func upgrade(_ app: AppItem) async -> Bool {
        guard !Self.dryRun else { return false }
        guard case .homebrew(let token)? = updates[app.id]?.source, !upgrading.contains(app.id) else { return false }
        upgrading.insert(app.id)
        let ok = await Homebrew.upgrade(token)
        upgrading.remove(app.id)
        if ok { updates[app.id] = nil }
        return ok
    }

    private static func sizeKey(_ app: AppItem, _ info: AppInfo?) -> String {
        app.url.path + "|" + (info?.version ?? "")
    }

    func checkUpdates(_ apps: [AppItem]) {
        guard checking == nil else { return }
        let targets = apps.compactMap(UpdateChecker.target(for:))
        checkable = targets.count
        checking = (0, targets.count)
        updates = [:]
        Task {
            async let brew = Homebrew.outdated()
            await UpdateChecker.check(targets) { id, update in
                if let update { self.updates[id] = update }
                self.checking?.done += 1
            }
            // Homebrew fills in what the apps' own feeds didn't report.
            for (fileName, cask) in await brew {
                guard let app = apps.first(where: { $0.url.lastPathComponent == fileName }), updates[app.id] == nil else { continue }
                updates[app.id] = AppUpdate(version: cask.version, source: .homebrew(cask.token))
            }
            checking = nil
            lastChecked = Date()
        }
    }
}

/// Launches through LaunchUS by day, for the usage statistics. Kept for eight weeks.
enum LaunchLog {
    private static let key = "launchLog"
    static let keepDays = 56

    /// Day ("2026-11-06") → app ID → launches.
    /// Read once and kept, since the heatmap asks on every redraw.
    private static let cache = OSAllocatedUnfairLock<[String: [String: Int]]?>(initialState: nil)

    static func load() -> [String: [String: Int]] {
        if let log = cache.withLock({ $0 }) { return log }
        let log = (UserDefaults.app.dictionary(forKey: key) as? [String: [String: Int]]) ?? [:]
        cache.withLock { $0 = log }
        return log
    }

    static func record(_ id: String, at date: Date = Date()) {
        let log = adding(id, at: date, to: load())
        cache.withLock { $0 = log }
        UserDefaults.app.set(log, forKey: key)
    }

    static func adding(_ id: String, at date: Date, to log: [String: [String: Int]]) -> [String: [String: Int]] {
        var log = log
        log[day(date), default: [:]][id, default: 0] += 1
        let oldest = day(Calendar.current.date(byAdding: .day, value: -keepDays, to: date) ?? date)
        return log.filter { $0.key > oldest }
    }

    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func reset() {
        cache.withLock { $0 = nil }
        UserDefaults.app.removeObject(forKey: key)
    }

    /// Launches per app over the last `days` days (today included), most first.
    static func top(_ log: [String: [String: Int]], days: Int, now: Date = Date()) -> [(id: String, count: Int)] {
        var totals: [String: Int] = [:]
        for day in lastDays(days, now: now) {
            for (id, count) in log[day] ?? [:] { totals[id, default: 0] += count }
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }

    /// Launches on each of the last `days` days, oldest first.
    static func perDay(_ log: [String: [String: Int]], days: Int, now: Date = Date()) -> [(date: Date, count: Int)] {
        (0..<days).reversed().compactMap { back in
            guard let date = Calendar.current.date(byAdding: .day, value: -back, to: now) else { return nil }
            return (Calendar.current.startOfDay(for: date), (log[day(date)] ?? [:]).values.reduce(0, +))
        }
    }

    private static func lastDays(_ days: Int, now: Date) -> [String] {
        (0..<days).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: now).map(day) }
    }
}
