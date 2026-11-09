import AppKit
import LocalAuthentication
import Observation
import UserNotifications

/// How long each app was in front, per day, for the heatmap widget and time limits. It is
/// measured from which app is frontmost and stays in `usage.json` on this Mac; nothing of it
/// is sent anywhere.
@MainActor @Observable
final class AppUsage {
    static let shared = AppUsage()
    static let keepDays = 182
    /// Time away from the keyboard and mouse longer than this doesn't count.
    static let idleLimit: TimeInterval = 300

    struct Limit: Codable, Equatable {
        var minutes: Int
        var action: Action = .hide
        /// "再用 15 分钟" lets the app be used until then.
        var extraUntil: Date?
    }

    enum Action: String, Codable, CaseIterable {
        /// A notification, nothing more.
        case remind
        /// The app is hidden each time it comes to the front.
        case hide
        /// The app is asked to quit, as with ⌘Q (it can still ask to save).
        case quit

        var title: String {
            switch self {
            case .remind: String(localized: "只提醒")
            case .hide: String(localized: "隐藏 App")
            case .quit: String(localized: "退出 App")
            }
        }
    }

    /// Day ("2026-11-09") → bundle ID → seconds in front.
    private(set) var log: [String: [String: Double]] = [:]
    /// Bundle ID → today's allowance.
    private(set) var limits: [String: Limit] = [:]
    /// Extending or changing a limit asks for Touch ID or the login password.
    private(set) var locked = false

    @ObservationIgnored private var current: (id: String, since: Date)?
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave = Date()
    /// Bundle ID → the day its warning or time-up note went out, so each goes once.
    @ObservationIgnored private var warned: [String: String] = [:]
    @ObservationIgnored private var toldUp: [String: String] = [:]
    @ObservationIgnored private var lastBlockNote: [String: Date] = [:]
    @ObservationIgnored private var extraWarned: [String: Date] = [:]
    @ObservationIgnored private var started = false
    /// Set once quitting is allowed (unlocked, or LaunchUS restarting itself).
    @ObservationIgnored var quitApproved = false

    /// Locked limits would stop counting if LaunchUS quit, so quitting asks first.
    var guardsQuit: Bool { locked && !limits.isEmpty && !quitApproved }

    static var url: URL { LayoutStore.directory.appendingPathComponent("usage.json") }

    private struct File: Codable {
        var log: [String: [String: Double]]
        var limits: [String: Limit]
        var locked: Bool?
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let file = try? JSONDecoder().decode(File.self, from: data) {
            log = file.log
            limits = file.limits
            locked = file.locked ?? false
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.switched(to: id, app: app) }
        }
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                                 (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
                                 (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(sleeping) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.credit()
                self?.save()
            }
        }
        let front = NSWorkspace.shared.frontmostApplication
        current = front?.bundleIdentifier.map { ($0, Date()) }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Measuring

    private func switched(to id: String?, app: NSRunningApplication?) {
        credit()
        current = id.map { ($0, Date()) }
        if let id, let app { enforce(id, app: app) }
    }

    private func setAsleep(_ sleeping: Bool) {
        if sleeping { credit() }
        asleep = sleeping
        if !sleeping, let id = current?.id { current = (id, Date()) }
    }

    private func tick() {
        credit()
        if let id = current?.id, let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == id {
            enforce(id, app: app)
        }
        if dirty, Date().timeIntervalSince(lastSave) > 60 { save() }
    }

    /// Adds the time since the last look to the app in front.
    private func credit(now: Date = Date()) {
        guard let (id, since) = current else { return }
        current = (id, now)
        guard !asleep else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let elapsed = now.timeIntervalSince(since)
        // Away from the Mac: only the part before the idle limit counts.
        let counted = idle > Self.idleLimit ? max(0, elapsed - (idle - Self.idleLimit)) : elapsed
        guard counted > 0, counted < 3600 else { return }
        log = Self.adding(counted, to: id, at: now, in: log)
        dirty = true
    }

    static func adding(_ seconds: Double, to id: String, at date: Date, in log: [String: [String: Double]]) -> [String: [String: Double]] {
        var log = log
        let day = LaunchLog.day(date)
        log[day, default: [:]][id, default: 0] += seconds
        if log.count > keepDays {
            let oldest = LaunchLog.day(Calendar.current.date(byAdding: .day, value: -keepDays, to: date) ?? date)
            log = log.filter { $0.key > oldest }
        }
        return log
    }

    /// Seconds in front today (or on `date`'s day).
    func seconds(_ id: String, on date: Date = Date()) -> Double {
        var total = log[LaunchLog.day(date)]?[id] ?? 0
        if let current, current.id == id, Calendar.current.isDate(date, inSameDayAs: Date()), !asleep {
            total += Date().timeIntervalSince(current.since)
        }
        return total
    }

    /// All apps' seconds on each day, or one app's.
    func total(on date: Date, app: String?) -> Double {
        if let app { return seconds(app, on: date) }
        let day = log[LaunchLog.day(date)] ?? [:]
        var total = day.values.reduce(0, +)
        if let current, Calendar.current.isDate(date, inSameDayAs: Date()), !asleep {
            total += Date().timeIntervalSince(current.since)
        }
        return total
    }

    /// The apps used most over the last `days` days, most first.
    func top(days: Int, now: Date = Date()) -> [(id: String, seconds: Double)] {
        var totals: [String: Double] = [:]
        for back in 0..<days {
            guard let date = Calendar.current.date(byAdding: .day, value: -back, to: now) else { continue }
            for (id, s) in log[LaunchLog.day(date)] ?? [:] { totals[id, default: 0] += s }
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    // MARK: Limits

    func limit(_ id: String) -> Limit? { limits[id] }

    func setLimit(_ limit: Limit?, for id: String) {
        limits[id] = limit
        warned[id] = nil
        toldUp[id] = nil
        save()
    }

    func setLocked(_ on: Bool) {
        locked = on
        save()
    }

    /// Today's time is used up and no extra time is running.
    func isOver(_ id: String) -> Bool {
        guard let limit = limits[id] else { return false }
        if let extra = limit.extraUntil, extra > Date() { return false }
        return seconds(id) >= Double(limit.minutes * 60)
    }

    /// Over the limit and the app is kept from being used (not just reminded).
    func isBlocked(_ id: String?) -> Bool {
        guard let id, let limit = limits[id] else { return false }
        return limit.action != .remind && isOver(id)
    }

    func extend(_ id: String, minutes: Int = 15) {
        guard var limit = limits[id] else { return }
        limit.extraUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        limits[id] = limit
        toldUp[id] = nil
        save()
    }

    private func enforce(_ id: String, app: NSRunningApplication) {
        guard let limit = limits[id] else { return }
        let today = LaunchLog.day(Date())
        let used = seconds(id)
        let allowed = Double(limit.minutes * 60)
        let name = app.localizedName ?? id
        // A minute before 再用 15 分钟 runs out, once for each extension.
        if let extra = limit.extraUntil, extra > Date(), extra.timeIntervalSinceNow <= 60, extraWarned[id] != extra,
           limit.action != .remind {
            extraWarned[id] = extra
            Self.notify(String(localized: "\(name) 还能用 1 分钟"), String(localized: "加的时间快用完了。"))
        }
        if limit.extraUntil.map({ $0 > Date() }) != true, used < allowed {
            if allowed - used <= 300, allowed >= 600, warned[id] != today {
                warned[id] = today
                Self.notify(String(localized: "\(name) 还能用 5 分钟"),
                            String(localized: "今天的限额是 \(limit.minutes) 分钟。"))
            }
            return
        }
        guard isOver(id) else { return }
        switch limit.action {
        case .remind:
            if toldUp[id] != today {
                toldUp[id] = today
                Self.notify(String(localized: "\(name) 今天的时间到了"),
                            String(localized: "今天已经用了 \(Int(used / 60)) 分钟，限额 \(limit.minutes) 分钟。"))
            }
        case .hide, .quit:
            if lastBlockNote[id].map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                lastBlockNote[id] = Date()
                Self.notify(String(localized: "\(name) 今天的时间到了"),
                            limit.action == .hide
                                ? String(localized: "已经隐藏。在启动台里点它可以再用 15 分钟。")
                                : String(localized: "已经退出。在启动台里点它可以再用 15 分钟。"))
            }
            if limit.action == .hide { app.hide() } else { app.terminate() }
        }
    }

    /// Touch ID or the login password, when limits are locked; straight through otherwise.
    func authorize(_ reason: String, denied: (@MainActor () -> Void)? = nil, then done: @escaping @MainActor () -> Void) {
        guard locked else {
            done()
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            done()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ok ? done() : denied?() } }
        }
    }

    private static func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func save() {
        dirty = false
        lastSave = Date()
        guard let data = try? JSONEncoder().encode(File(log: log, limits: limits, locked: locked)) else { return }
        try? FileManager.default.createDirectory(at: LayoutStore.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    /// For 清除使用记录: the measured time goes, the limits stay.
    func resetLog() {
        log = [:]
        current = current.map { ($0.id, Date()) }
        save()
    }
}

/// "1 小时 20 分", "45 分", "< 1 分".
func usageText(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return String(localized: "不到 1 分钟") }
    if minutes < 60 { return String(localized: "\(minutes) 分钟") }
    let hours = minutes / 60, rest = minutes % 60
    return rest == 0 ? String(localized: "\(hours) 小时") : String(localized: "\(hours) 小时 \(rest) 分")
}
