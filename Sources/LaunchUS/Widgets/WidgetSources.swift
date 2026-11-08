import AppKit
import Darwin
import IOKit
import IOKit.ps

// What the newer built-in widgets show: battery details and accessories, volumes, the local
// address, holidays and how far along the day, week, month and year are.

/// The Mac's own battery, from the power source list and the battery controller.
struct BatteryDetails: Equatable {
    var level: Double
    var charging: Bool
    var pluggedIn: Bool
    /// Minutes to empty or to full; nil while macOS is still working it out.
    var minutesLeft: Int?
    var cycles: Int?
    /// Full charge now against when new, 0–1.
    var health: Double?
    var temperature: Double?

    @MainActor static func read() -> BatteryDetails? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            var details = BatteryDetails(level: Double(current) / Double(max), charging: charging, pluggedIn: plugged,
                                         minutesLeft: minutes.flatMap { $0 > 0 ? $0 : nil })
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                // Newer macOS keeps the capacities only inside "BatteryData".
                let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                func value(_ key: String) -> Int? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
                        ?? data?[key] as? Int
                }
                details.cycles = value("CycleCount")
                if let full = value("AppleRawMaxCapacity") ?? value("NominalChargeCapacity"), let design = value("DesignCapacity"), design > 0 {
                    details.health = min(1, Double(full) / Double(design))
                }
                if let t = value("Temperature") { details.temperature = Double(t) / 100 }
            }
            return details
        }
        return nil
    }
}

/// A Bluetooth keyboard, mouse or trackpad that reports its charge.
struct Accessory: Equatable, Identifiable {
    var name: String
    var level: Double
    var id: String { name }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("keyboard") || n.contains("键盘") { return "keyboard" }
        if n.contains("trackpad") || n.contains("触控板") { return "rectangle.and.hand.point.up.left" }
        if n.contains("mouse") || n.contains("鼠标") { return "magicmouse" }
        if n.contains("pencil") { return "applepencil" }
        return "dot.radiowaves.left.and.right"
    }

    @MainActor static func read() -> [Accessory] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Accessory] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = property("BatteryPercent") as? Int, let name = property("Product") as? String,
                  !found.contains(where: { $0.name == name }) else { continue }
            found.append(Accessory(name: name, level: Double(min(100, max(0, percent))) / 100))
        }
        return found.sorted { $0.name < $1.name }
    }
}

/// A mounted disk with room on it.
struct VolumeUsage: Equatable, Identifiable {
    var name: String
    var used: Int64
    var total: Int64
    var removable: Bool
    var isStartup: Bool
    var id: String { name }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var free: Int64 { max(0, total - used) }

    @MainActor private static var cache: (time: Date, volumes: [VolumeUsage])?

    /// Checked at most every half minute; asking a sleeping external disk wakes it up.
    @MainActor static func read() -> [VolumeUsage] {
        if let cache, Date().timeIntervalSince(cache.time) < 30 { return cache.volumes }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey,
                                      .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var volumes: [VolumeUsage] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            let root = v.volumeIsRootFileSystem == true || url.path == "/"
            volumes.append(VolumeUsage(name: v.volumeLocalizedName ?? url.lastPathComponent, used: max(0, Int64(total) - free),
                                       total: Int64(total), removable: v.volumeIsRemovable == true || v.volumeIsEjectable == true,
                                       isStartup: root))
        }
        volumes.sort { ($0.isStartup ? 0 : 1, $0.name) < ($1.isStartup ? 0 : 1, $1.name) }
        cache = (Date(), volumes)
        return volumes
    }
}

enum NetworkInfo {
    /// The Mac's address on the local network, Wi-Fi or Ethernet.
    static func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var best: (name: String, address: String)?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            // en0 first: it's the built-in Wi-Fi or Ethernet.
            if best == nil || name < best!.name { best = (name, address) }
        }
        return best?.address
    }
}

/// How much of the day, week, month and year has gone.
struct TimeProgress {
    enum Span: CaseIterable { case day, week, month, year }

    static func fraction(_ span: Span, at now: Date, calendar: Calendar = .current) -> Double {
        let component: Calendar.Component = switch span {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        guard let interval = calendar.dateInterval(of: component, for: now), interval.duration > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(interval.start) / interval.duration))
    }

    /// What's left: hours of the day, days of the rest.
    static func remaining(_ span: Span, at now: Date, calendar: Calendar = .current) -> String {
        let component: Calendar.Component = switch span {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        guard let end = calendar.dateInterval(of: component, for: now)?.end else { return "" }
        if span == .day {
            let hours = Int(end.timeIntervalSince(now) / 3600)
            return hours > 0 ? String(localized: "还剩 \(hours) 小时") : String(localized: "还剩不到 1 小时")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: end).day ?? 0
        return String(localized: "还剩 \(days) 天")
    }
}

/// Holidays and festivals coming up: the Chinese ones for Chinese-speaking users, the
/// Western ones for everyone else.
struct Holiday: Equatable, Identifiable {
    var name: String
    var date: Date
    var symbol: String
    var id: String { name + date.description }

    /// Whole days from today; 0 is today.
    func days(from now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    @MainActor private static var cache: (day: Date, chinese: Bool, list: [Holiday])?

    @MainActor static func upcoming(from now: Date, chinese: Bool = Locale.preferredLanguages.first?.hasPrefix("zh") == true) -> [Holiday] {
        let today = Calendar.current.startOfDay(for: now)
        if let cache, cache.day == today, cache.chinese == chinese { return cache.list }
        let list = compute(from: today, chinese: chinese)
        cache = (today, chinese, list)
        return list
    }

    static func compute(from today: Date, chinese: Bool, calendar: Calendar = .current) -> [Holiday] {
        let year = calendar.component(.year, from: today)
        var all: [Holiday] = []
        for y in [year, year + 1] {
            func solar(_ month: Int, _ day: Int) -> Date? { calendar.date(from: DateComponents(year: y, month: month, day: day)) }
            if chinese {
                all += [
                    solar(1, 1).map { Holiday(name: String(localized: "元旦"), date: $0, symbol: "sparkles") },
                    solar(2, 14).map { Holiday(name: String(localized: "情人节"), date: $0, symbol: "heart.fill") },
                    qingming(y, calendar: calendar).map { Holiday(name: String(localized: "清明"), date: $0, symbol: "leaf.fill") },
                    solar(5, 1).map { Holiday(name: String(localized: "劳动节"), date: $0, symbol: "hammer.fill") },
                    solar(10, 1).map { Holiday(name: String(localized: "国庆节"), date: $0, symbol: "flag.fill") },
                    solar(12, 25).map { Holiday(name: String(localized: "圣诞节"), date: $0, symbol: "tree.fill") },
                ].compactMap { $0 }
                let lunar: [(Int, Int, String, String)] = [
                    (1, 1, String(localized: "春节"), "fireworks"),
                    (1, 15, String(localized: "元宵节"), "moon.stars.fill"),
                    (5, 5, String(localized: "端午节"), "sailboat.fill"),
                    (7, 7, String(localized: "七夕"), "star.fill"),
                    (8, 15, String(localized: "中秋节"), "moon.fill"),
                    (9, 9, String(localized: "重阳节"), "mountain.2.fill"),
                ]
                for (month, day, name, symbol) in lunar {
                    if let date = lunarDate(year: y, month: month, day: day, calendar: calendar) {
                        all.append(Holiday(name: name, date: date, symbol: symbol))
                        if month == 1, day == 1, let eve = calendar.date(byAdding: .day, value: -1, to: date) {
                            all.append(Holiday(name: String(localized: "除夕"), date: eve, symbol: "fireworks"))
                        }
                    }
                }
            } else {
                all += [
                    solar(1, 1).map { Holiday(name: String(localized: "元旦"), date: $0, symbol: "sparkles") },
                    solar(2, 14).map { Holiday(name: String(localized: "情人节"), date: $0, symbol: "heart.fill") },
                    easter(y, calendar: calendar).map { Holiday(name: String(localized: "复活节"), date: $0, symbol: "hare.fill") },
                    solar(10, 31).map { Holiday(name: String(localized: "万圣节"), date: $0, symbol: "moon.haze.fill") },
                    thanksgiving(y, calendar: calendar).map { Holiday(name: String(localized: "感恩节"), date: $0, symbol: "fork.knife") },
                    solar(12, 25).map { Holiday(name: String(localized: "圣诞节"), date: $0, symbol: "tree.fill") },
                    solar(12, 31).map { Holiday(name: String(localized: "跨年夜"), date: $0, symbol: "party.popper.fill") },
                ].compactMap { $0 }
            }
        }
        return all.filter { $0.date >= today }.sorted { $0.date < $1.date }
    }

    /// The Gregorian date of a day in the Chinese calendar, in the lunar year that starts in `year`.
    static func lunarDate(year: Int, month: Int, day: Int, calendar: Calendar = .current) -> Date? {
        let chinese = Calendar(identifier: .chinese)
        // Lunar new year falls between 21 January and 20 February.
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 20)) else { return nil }
        var components = DateComponents(month: month, day: day)
        components.isLeapMonth = false
        guard let date = chinese.nextDate(after: start, matching: components, matchingPolicy: .strict) else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// 4 or 5 April, from the usual formula for the 21st century.
    static func qingming(_ year: Int, calendar: Calendar) -> Date? {
        let y = year % 100
        let day = Int(Double(y) * 0.2422 + 4.81) - y / 4
        return calendar.date(from: DateComponents(year: year, month: 4, day: day))
    }

    /// Western Easter Sunday (anonymous Gregorian algorithm).
    static func easter(_ year: Int, calendar: Calendar) -> Date? {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The fourth Thursday of November.
    static func thanksgiving(_ year: Int, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: 11, weekday: 5, weekdayOrdinal: 4))
    }
}
