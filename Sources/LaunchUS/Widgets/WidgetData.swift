import AppKit
import Darwin
import EventKit
import IOKit.ps
import Observation

/// One reading of the Mac's load, for the system widget.
struct SystemSample: Equatable {
    /// 0...1 across all cores since the previous reading.
    var cpu: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var diskUsed: Int64 = 0
    var diskTotal: Int64 = 0
    /// 0...1, nil without a battery.
    var battery: Double?
    var charging = false
    /// Bytes per second since the previous reading.
    var download: Double = 0
    var upload: Double = 0

    var memory: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    var disk: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }
}

/// Reads CPU, memory, disk, battery and network use. Rates are measured between two calls.
@MainActor
final class SystemStats {
    static let shared = SystemStats()

    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastBytes: (down: UInt64, up: UInt64, time: Date)?
    private var lastSample = SystemSample()
    private var lastTime = Date.distantPast
    private var disk: (used: Int64, total: Int64, time: Date)?
    /// The last two minutes of readings, oldest first, for the graphs.
    private(set) var history: [SystemSample] = []
    static let historyLength = 60
    /// Bytes moved since LaunchUS first looked.
    private(set) var totalDown: Double = 0
    private(set) var totalUp: Double = 0

    /// Several widgets on screen share one reading a second.
    func sample() -> SystemSample {
        let now = Date()
        guard now.timeIntervalSince(lastTime) > 0.8 else { return lastSample }
        lastTime = now
        var s = SystemSample()
        s.cpu = cpuLoad()
        (s.memoryUsed, s.memoryTotal) = memory()
        if disk == nil || now.timeIntervalSince(disk!.time) > 60 {
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
            disk = (max(0, total - free), total, now)
        }
        s.diskUsed = disk?.used ?? 0
        s.diskTotal = disk?.total ?? 0
        (s.battery, s.charging) = battery()
        let bytes = networkBytes()
        if let last = lastBytes {
            let dt = max(0.1, now.timeIntervalSince(last.time))
            s.download = Double(bytes.down &- last.down) / dt
            s.upload = Double(bytes.up &- last.up) / dt
            // Counters reset (an interface went away): no rate this time.
            if bytes.down < last.down { s.download = 0 }
            if bytes.up < last.up { s.upload = 0 }
        }
        if let last = lastBytes {
            totalDown += s.download * max(0.1, now.timeIntervalSince(last.time))
            totalUp += s.upload * max(0.1, now.timeIntervalSince(last.time))
        }
        lastBytes = (bytes.down, bytes.up, now)
        lastSample = s
        history.append(s)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        return s
    }

    private func cpuLoad() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return lastSample.cpu }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return lastSample.cpu }
        return min(1, max(0, Double(busy - last.busy) / Double(total - last.total)))
    }

    private func memory() -> (UInt64, UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        // What Activity Monitor calls "Memory Used": app memory, wired and compressed.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private func battery() -> (Double?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (Double(current) / Double(max), d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return (nil, false)
    }

    private func networkBytes() -> (down: UInt64, up: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var down: UInt64 = 0, up: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            // Real interfaces only: not loopback, tunnels or bridges counting the same bytes again.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(d.ifi_ibytes)
            up += UInt64(d.ifi_obytes)
        }
        return (down, up)
    }
}

/// Today's events and open reminders for the calendar widget.
@MainActor @Observable
final class WidgetEvents {
    static let shared = WidgetEvents()

    struct Event: Identifiable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var color: NSColor
    }

    struct Reminder: Identifiable, Equatable {
        var id: String
        var title: String
        var due: Date?
        var color: NSColor
    }

    private(set) var events: [Event] = []
    private(set) var reminders: [Reminder] = []
    private(set) var eventsAllowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    private(set) var remindersAllowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    /// Access was asked for and refused (or is restricted): the widget points to System Settings.
    var denied: Bool {
        let e = EKEventStore.authorizationStatus(for: .event), r = EKEventStore.authorizationStatus(for: .reminder)
        return (e == .denied || e == .restricted) && (r == .denied || r == .restricted)
    }
    var notAsked: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
            || EKEventStore.authorizationStatus(for: .reminder) == .notDetermined
    }

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(force: true) }
        }
    }

    func requestAccess() {
        Task { @MainActor in
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await store.requestFullAccessToEvents()
            }
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                _ = try? await store.requestFullAccessToReminders()
            }
            reload(force: true)
        }
    }

    /// Re-reads at most once a minute unless something changed.
    func reload(force: Bool = false) {
        eventsAllowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersAllowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        guard force || Date().timeIntervalSince(lastLoad) > 60 else { return }
        lastLoad = Date()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        if eventsAllowed, let end = cal.date(byAdding: .day, value: 1, to: start) {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let found = store.events(matching: predicate)
                .filter { $0.endDate > Date() || $0.isAllDay }
                .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
                .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "", start: $0.startDate,
                             end: $0.endDate, allDay: $0.isAllDay, color: $0.calendar?.color ?? .systemBlue) }
            if found != events { events = found }
        } else if !events.isEmpty {
            events = []
        }
        if remindersAllowed {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { items in
                let list = (items ?? []).map { r in
                    Reminder(id: r.calendarItemIdentifier, title: r.title ?? "",
                             due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                             color: r.calendar?.color ?? .systemOrange)
                }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                Task { @MainActor in
                    if list != self.reminders { self.reminders = list }
                }
            }
        } else if !reminders.isEmpty {
            reminders = []
        }
    }
}
