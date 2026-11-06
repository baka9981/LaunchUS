import Foundation

/// Space in the empty search field opens these lists instead of typing a space: a guess at
/// what's wanted now, the most recently opened, the most opened. Space again or → goes to
/// the next one, ← back.
enum SpaceShortcut: Int, CaseIterable {
    case guess, recent, mostUsed

    /// The next list (or previous, for -1), going round.
    func step(_ by: Int) -> SpaceShortcut {
        let all = Self.allCases
        return all[((rawValue + by) % all.count + all.count) % all.count]
    }

    var title: String {
        switch self {
        case .guess: String(localized: "猜你想找")
        case .recent: String(localized: "最近使用")
        case .mostUsed: String(localized: "最常使用")
        }
    }

    /// How many apps a guess offers.
    static let guessLimit = 12

    /// - recent: opened through LaunchUS, newest first, then the system's last-used dates.
    /// - hours: launches through LaunchUS by app and hour of day (`LaunchHours`).
    func apps(from apps: [AppItem], recent: [String], hours: [String: [Int]],
              now: Date = Date(), ownID: String? = Bundle.main.bundleIdentifier) -> [AppItem] {
        let pool = apps.filter { $0.id != ownID }
        switch self {
        case .recent:
            return RecentLaunches.row(apps: pool, recent: recent, pinned: [], removed: [],
                                      limit: pool.count, ownID: ownID)
        case .mostUsed:
            return pool.filter { $0.useCount > 0 }.sorted {
                $0.useCount != $1.useCount ? $0.useCount > $1.useCount
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .guess:
            let scored = pool.map { ($0, Self.guessScore($0, recent: recent, hours: hours, now: now)) }
                .filter { $0.1 > 0 }
            return scored.sorted {
                $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
            }.prefix(Self.guessLimit).map(\.0)
        }
    }

    /// What's usually opened around this hour counts most, then what was opened lately
    /// here, then how often and how lately the system says it's used.
    static func guessScore(_ app: AppItem, recent: [String], hours: [String: [Int]], now: Date) -> Double {
        var score = 0.0
        if let counts = hours[app.id], counts.count == 24 {
            let hour = Calendar.current.component(.hour, from: now)
            score += 3 * Double(counts[hour]) + 1.5 * Double(counts[(hour + 23) % 24] + counts[(hour + 1) % 24])
        }
        if let index = recent.firstIndex(of: app.id) { score += max(0, 10 - Double(index)) }
        if app.useCount > 0, let used = app.lastUsedDate {
            let days = max(0, now.timeIntervalSince(used) / 86_400)
            score += 4 * log2(Double(app.useCount) + 1) / (1 + days / 7)
        }
        return score
    }
}

/// Launches through LaunchUS counted by hour of day, for `SpaceShortcut.guess`.
enum LaunchHours {
    private static let key = "launchHours"
    /// Counts are halved past this so old habits fade.
    private static let cap = 60

    static func load() -> [String: [Int]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]]) ?? [:]
    }

    static func record(_ id: String, at date: Date = Date()) {
        var all = load()
        all[id] = adding(Calendar.current.component(.hour, from: date), to: all[id])
        UserDefaults.standard.set(all, forKey: key)
    }

    static func adding(_ hour: Int, to counts: [Int]?) -> [Int] {
        var counts = counts?.count == 24 ? counts! : Array(repeating: 0, count: 24)
        counts[hour] += 1
        if counts.reduce(0, +) > cap { counts = counts.map { $0 / 2 } }
        return counts
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}
