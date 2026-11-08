import AppKit
import SwiftUI
import UserNotifications

// The widgets you use rather than read: a sticky note, the apps you open most, a timer and a
// row of quick actions. Clicks on them land on a spot (an icon, a button), so each one lays
// itself out with a function the launcher also uses to find what was clicked.

/// The launcher, for widgets that show its apps or open them.
@MainActor
enum WidgetHost {
    static weak var model: LauncherModel?
}

// MARK: - Saved state

/// What the note and timer widgets keep, per widget, in
/// `~/Library/Application Support/LaunchUS/widgets.json`.
@MainActor @Observable
final class WidgetStore {
    static let shared = WidgetStore()

    struct Note: Codable, Equatable {
        var text = ""
        var color: NoteColor = .yellow
    }

    struct TimerState: Codable, Equatable {
        var minutes = 25
        /// Running: when it rings.
        var end: Date?
        /// Paused: what was left.
        var left: TimeInterval?

        var total: TimeInterval { TimeInterval(minutes * 60) }
        func remaining(at now: Date) -> TimeInterval {
            if let end { return max(0, end.timeIntervalSince(now)) }
            return left ?? total
        }
        var isRunning: Bool { end != nil }
        func isFinished(at now: Date) -> Bool { end.map { $0 <= now } ?? false }
    }

    struct Todo: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var text: String
        var done = false
    }

    private struct File: Codable {
        var notes: [String: Note] = [:]
        var timers: [String: TimerState] = [:]
        var todos: [String: [Todo]] = [:]
        var groups: [String: String] = [:]
        var photos: [String: Photo] = [:]

        init(notes: [String: Note], timers: [String: TimerState], todos: [String: [Todo]],
             groups: [String: String], photos: [String: Photo]) {
            self.notes = notes
            self.timers = timers
            self.todos = todos
            self.groups = groups
            self.photos = photos
        }

        /// Older files have no to-dos yet.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notes = try c.decodeIfPresent([String: Note].self, forKey: .notes) ?? [:]
            timers = try c.decodeIfPresent([String: TimerState].self, forKey: .timers) ?? [:]
            todos = try c.decodeIfPresent([String: [Todo]].self, forKey: .todos) ?? [:]
            groups = try c.decodeIfPresent([String: String].self, forKey: .groups) ?? [:]
            photos = try c.decodeIfPresent([String: Photo].self, forKey: .photos) ?? [:]
        }
    }

    private(set) var notes: [String: Note] = [:]
    private(set) var timers: [String: TimerState] = [:]
    private(set) var todos: [String: [Todo]] = [:]
    /// App group widgets: which folder each one opens.
    private(set) var groups: [String: String] = [:]
    private(set) var photos: [String: Photo] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var rings: [String: DispatchWorkItem] = [:]
    /// Tests keep their notes to themselves.
    @ObservationIgnored var persists = true

    static var url: URL { LayoutStore.directory.appendingPathComponent("widgets.json") }

    init() {
        if let data = try? Data(contentsOf: Self.url), let file = try? JSONDecoder().decode(File.self, from: data) {
            notes = file.notes
            timers = file.timers
            todos = file.todos
            groups = file.groups
            photos = file.photos
        }
        for id in timers.keys { schedule(id) }
    }

    // MARK: Notes

    func note(_ id: String) -> Note {
        if id.hasPrefix("preview-") {
            return Note(text: String(localized: "## 今天\n- [x] 买牛奶\n- [ ] 周五前交**报告**\n- 给妈妈打电话"))
        }
        return notes[id] ?? Note()
    }

    func setNoteText(_ text: String, _ id: String) {
        guard notes[id, default: Note()].text != text else { return }
        notes[id, default: Note()].text = text
        save(soon: true)
    }

    func setNoteColor(_ color: NoteColor, _ id: String) {
        notes[id, default: Note()].color = color
        save()
    }

    // MARK: To-dos

    func todoList(_ id: String) -> [Todo] {
        if id.hasPrefix("preview-") {
            return [Todo(text: String(localized: "回复邮件")), Todo(text: String(localized: "预约体检")),
                    Todo(text: String(localized: "整理桌面")), Todo(text: String(localized: "买牛奶"), done: true)]
        }
        return todos[id] ?? []
    }

    func addTodo(_ text: String, _ id: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        todos[id, default: []].append(Todo(text: text))
        save()
    }

    func toggleTodo(_ item: String, _ id: String) {
        guard let i = todos[id]?.firstIndex(where: { $0.id == item }) else { return }
        todos[id]?[i].done.toggle()
        save()
    }

    func removeTodo(_ item: String, _ id: String) {
        todos[id]?.removeAll { $0.id == item }
        save()
    }

    func clearDoneTodos(_ id: String) {
        todos[id]?.removeAll(where: \.done)
        save()
    }

    // MARK: Timers

    func timer(_ id: String) -> TimerState { timers[id] ?? TimerState() }

    /// Start, pause, carry on, or after it rang, back to the start.
    func toggleTimer(_ id: String, now: Date = Date()) {
        var t = timer(id)
        if t.isFinished(at: now) {
            t.end = nil
            t.left = nil
        } else if let end = t.end {
            t.left = max(0, end.timeIntervalSince(now))
            t.end = nil
        } else {
            t.end = now.addingTimeInterval(t.left ?? t.total)
            t.left = nil
            Self.askToNotify()
        }
        update(t, id)
    }

    /// A new length starts straight away.
    func startTimer(_ id: String, minutes: Int, now: Date = Date()) {
        var t = timer(id)
        t.minutes = minutes
        t.end = now.addingTimeInterval(t.total)
        t.left = nil
        Self.askToNotify()
        update(t, id)
    }

    func resetTimer(_ id: String) {
        var t = timer(id)
        t.end = nil
        t.left = nil
        update(t, id)
    }

    private func update(_ t: TimerState, _ id: String) {
        timers[id] = t
        schedule(id)
        save()
    }

    private func schedule(_ id: String) {
        rings[id]?.cancel()
        rings[id] = nil
        guard let end = timers[id]?.end, end > Date() else { return }
        let minutes = timers[id]?.minutes ?? 0
        let work = DispatchWorkItem { [weak self] in
            self?.rings[id] = nil
            Self.ring(minutes: minutes)
        }
        rings[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + end.timeIntervalSinceNow, execute: work)
    }

    /// Notifications need a real app bundle; the test runner has none.
    private static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private static func askToNotify() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func ring(minutes: Int) {
        NSSound(named: "Glass")?.play()
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "时间到")
        content.body = String(localized: "\(minutes) 分钟的计时结束了。")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Groups and photos

    func group(_ id: String) -> String? { groups[id] }

    func setGroup(_ folderID: String?, _ id: String) {
        groups[id] = folderID
        save()
    }

    func photo(_ id: String) -> Photo { photos[id] ?? Photo() }

    func setPhoto(_ photo: Photo, _ id: String) {
        guard photos[id] != photo else { return }
        if let old = photos[id]?.file, old != photo.file { WidgetPhotos.remove(old) }
        photos[id] = photo
        save(soon: true)
    }

    /// A removed widget takes its note, timer and picture with it.
    func forget(_ id: String) {
        guard notes[id] != nil || timers[id] != nil || todos[id] != nil || groups[id] != nil || photos[id] != nil else { return }
        notes[id] = nil
        timers[id] = nil
        todos[id] = nil
        groups[id] = nil
        if let file = photos[id]?.file { WidgetPhotos.remove(file) }
        photos[id] = nil
        rings[id]?.cancel()
        rings[id] = nil
        save()
    }

    private func save(soon: Bool = false) {
        guard persists else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let file = File(notes: notes, timers: timers, todos: todos, groups: groups, photos: photos)
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? FileManager.default.createDirectory(at: LayoutStore.directory, withIntermediateDirectories: true)
            try? data.write(to: Self.url, options: .atomic)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (soon ? 0.6 : 0), execute: work)
    }
}

/// Sticky-note paper.
enum NoteColor: String, Codable, CaseIterable {
    case yellow, green, blue, pink, purple, gray

    var title: String {
        switch self {
        case .yellow: String(localized: "黄色")
        case .green: String(localized: "绿色")
        case .blue: String(localized: "蓝色")
        case .pink: String(localized: "粉色")
        case .purple: String(localized: "紫色")
        case .gray: String(localized: "灰色")
        }
    }

    var paper: Color {
        switch self {
        case .yellow: Color(red: 1, green: 0.93, blue: 0.56)
        case .green: Color(red: 0.76, green: 0.93, blue: 0.66)
        case .blue: Color(red: 0.7, green: 0.86, blue: 1)
        case .pink: Color(red: 1, green: 0.78, blue: 0.84)
        case .purple: Color(red: 0.86, green: 0.78, blue: 1)
        case .gray: Color(red: 0.9, green: 0.9, blue: 0.9)
        }
    }

    /// A slightly darker band along the top, like the real thing.
    var band: Color {
        switch self {
        case .yellow: Color(red: 0.98, green: 0.86, blue: 0.4)
        case .green: Color(red: 0.64, green: 0.87, blue: 0.53)
        case .blue: Color(red: 0.56, green: 0.78, blue: 0.98)
        case .pink: Color(red: 0.98, green: 0.66, blue: 0.75)
        case .purple: Color(red: 0.77, green: 0.66, blue: 0.98)
        case .gray: Color(red: 0.82, green: 0.82, blue: 0.82)
        }
    }
}

// MARK: - Layout shared by drawing and clicking

enum ToolGrid {
    /// `count` equal cells, `columns` across, filling `size` row by row.
    static func cells(count: Int, columns: Int, rows: Int, in size: CGSize, gap: CGFloat = 0) -> [CGRect] {
        guard columns > 0, rows > 0 else { return [] }
        let w = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let h = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<min(count, columns * rows)).map { i in
            CGRect(x: CGFloat(i % columns) * (w + gap), y: CGFloat(i / columns) * (h + gap), width: w, height: h)
        }
    }

    /// The card's content area: the same margin `WidgetCard` leaves round built-in widgets.
    static func content(_ card: CGSize) -> (inset: CGFloat, size: CGSize) {
        let inset = min(card.width, card.height) * 0.09
        return (inset, CGSize(width: card.width - inset * 2, height: card.height - inset * 2))
    }

    /// A point on the card in content coordinates.
    static func local(_ point: CGPoint, card: CGSize) -> CGPoint {
        let inset = content(card).inset
        return CGPoint(x: point.x - inset, y: point.y - inset)
    }
}
