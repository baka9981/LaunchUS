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

        init(notes: [String: Note], timers: [String: TimerState], todos: [String: [Todo]]) {
            self.notes = notes
            self.timers = timers
            self.todos = todos
        }

        /// Older files have no to-dos yet.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notes = try c.decodeIfPresent([String: Note].self, forKey: .notes) ?? [:]
            timers = try c.decodeIfPresent([String: TimerState].self, forKey: .timers) ?? [:]
            todos = try c.decodeIfPresent([String: [Todo]].self, forKey: .todos) ?? [:]
        }
    }

    private(set) var notes: [String: Note] = [:]
    private(set) var timers: [String: TimerState] = [:]
    private(set) var todos: [String: [Todo]] = [:]
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

    /// A removed widget takes its note and timer with it.
    func forget(_ id: String) {
        guard notes[id] != nil || timers[id] != nil || todos[id] != nil else { return }
        notes[id] = nil
        timers[id] = nil
        todos[id] = nil
        rings[id]?.cancel()
        rings[id] = nil
        save()
    }

    private func save(soon: Bool = false) {
        guard persists else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let file = File(notes: notes, timers: timers, todos: todos)
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

// MARK: - Note

struct NoteWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat

    var body: some View {
        let note = WidgetStore.shared.note(id)
        Group {
            if note.text.isEmpty {
                VStack(alignment: .leading, spacing: unit * 0.06) {
                    Image(systemName: "square.and.pencil").font(.system(size: unit * 0.2))
                    Text(String(localized: "点一下写点什么")).font(.system(size: unit * 0.13, weight: .medium))
                }
                .opacity(0.4)
            } else {
                NoteMarkdown(text: note.text, unit: unit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func font(_ unit: CGFloat) -> Font { .system(size: unit * 0.15, weight: .medium, design: .rounded) }
}

/// The note's text read as Markdown: headings, lists, check boxes, quotes and rules, with
/// bold, italic, code and links inside a line. What it can't read stays as typed.
enum Markdown {
    enum Block: Equatable {
        case heading(Int, String)
        case bullet(String)
        case task(Bool, String)
        case numbered(String, String)
        case quote(String)
        case rule
        case paragraph(String)
        case blank
    }

    static func blocks(_ text: String) -> [Block] {
        text.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .blank }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3, Set(line).count == 1 { return .rule }
            if ["<hr>", "<hr/>", "<hr />"].contains(line.lowercased()) { return .rule }
            if let hashes = line.firstIndex(where: { $0 != "#" }), hashes != line.startIndex,
               line[hashes] == " ", line.distance(from: line.startIndex, to: hashes) <= 6 {
                return .heading(line.distance(from: line.startIndex, to: hashes), String(line[hashes...]).trimmingCharacters(in: .whitespaces))
            }
            for mark in ["- ", "* ", "+ "] where line.hasPrefix(mark) {
                let rest = String(line.dropFirst(2))
                for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where rest.hasPrefix(box) {
                    return .task(done, String(rest.dropFirst(4)))
                }
                if rest == "[ ]" { return .task(false, "") }
                if rest == "[x]" || rest == "[X]" { return .task(true, "") }
                return .bullet(rest)
            }
            if let dot = line.firstIndex(where: { !$0.isNumber }), dot != line.startIndex,
               line[dot...].hasPrefix(". ") || line[dot...].hasPrefix(") ") {
                return .numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...]))
            }
            if line.hasPrefix(">") { return .quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) }
            return .paragraph(line)
        }
    }

    /// Bold, italic, `code`, ~~strike~~ and links inside one line. Each run gets its font
    /// spelled out, since a font set on the whole text would wash the emphasis out.
    static func inline(_ text: String, size: CGFloat = 13, weight: Font.Weight = .medium) -> AttributedString {
        guard var out = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in out.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = Font.system(size: size, weight: intent.contains(.stronglyEmphasized) ? .heavy : weight,
                                   design: intent.contains(.code) ? .monospaced : .rounded)
            if intent.contains(.emphasized) { font = font.italic() }
            out[run.range].font = font
            if intent.contains(.strikethrough) { out[run.range].strikethroughStyle = .single }
            if run.link != nil { out[run.range].underlineStyle = .single }
        }
        return out
    }
}

struct NoteMarkdown: View {
    let text: String
    let unit: CGFloat

    var body: some View {
        let size = unit * 0.15
        VStack(alignment: .leading, spacing: unit * 0.04) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                row(block, size: size)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func row(_ block: Markdown.Block, size: CGFloat) -> some View {
        let body = Font.system(size: size, weight: .medium, design: .rounded)
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text, size: size * (level == 1 ? 1.45 : level == 2 ? 1.25 : 1.1), weight: .bold))
                .padding(.top, size * 0.15)
        case .bullet(let text):
            marked(Text(verbatim: "•").font(body.weight(.bold)), text, font: body, size: size)
        case .task(let done, let text):
            marked(Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: size * 0.95)),
                   text, font: body, size: size, done: done)
        case .numbered(let n, let text):
            marked(Text(n + ".").font(body).monospacedDigit(), text, font: body, size: size)
        case .quote(let text):
            HStack(spacing: size * 0.5) {
                Capsule().fill(.primary.opacity(0.35)).frame(width: size * 0.18)
                Text(Markdown.inline(text, size: size)).italic().opacity(0.75)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(.primary.opacity(0.25)).frame(height: 1).padding(.vertical, size * 0.2)
        case .paragraph(let text):
            Text(Markdown.inline(text, size: size)).lineSpacing(unit * 0.03)
        case .blank:
            Color.clear.frame(height: size * 0.4)
        }
    }

    private func marked(_ mark: some View, _ text: String, font: Font, size: CGFloat, done: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.45) {
            mark.frame(minWidth: size * 0.7, alignment: .leading)
            Text(Markdown.inline(text, size: size))
                .strikethrough(done)
                .opacity(done ? 0.5 : 1)
                .lineSpacing(unit * 0.03)
        }
    }
}

/// Typing on the note, in place. Esc or a click elsewhere puts it down.
struct NoteEditor: View {
    let id: String
    let unit: CGFloat
    @State private var text: String
    @FocusState private var focused: Bool

    /// Starts with the note's text, so the first frame isn't blank.
    init(id: String, unit: CGFloat) {
        self.id = id
        self.unit = unit
        _text = State(initialValue: WidgetStore.shared.note(id).text)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(NoteWidget.font(unit))
            .lineSpacing(unit * 0.03)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($focused)
            // TextEditor indents its text a little; this keeps it where the note drew it.
            .padding(.leading, -5)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: text) { _, new in WidgetStore.shared.setNoteText(new, id) }
    }
}

// MARK: - Frequent apps

struct AppsWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize

    static func shape(_ size: WidgetItem.Size) -> (columns: Int, rows: Int) {
        switch size {
        case .small: (2, 2)
        case .medium: (4, 2)
        case .large: (4, 4)
        }
    }

    @MainActor static func apps(for size: WidgetItem.Size) -> [AppItem] {
        guard let model = WidgetHost.model else { return [] }
        _ = model.widgetLaunches
        let (c, r) = shape(size)
        return RecentLaunches.row(apps: model.visibleApps, recent: RecentLaunches.load(), pinned: RecentLaunches.pinned,
                                  removed: RecentLaunches.removed, limit: c * r, ownID: Bundle.main.bundleIdentifier)
    }

    /// The app under a click on the card.
    @MainActor static func app(at point: CGPoint, size: WidgetItem.Size, card: CGSize) -> AppItem? {
        let apps = apps(for: size)
        let (c, r) = shape(size)
        let local = ToolGrid.local(point, card: card)
        let cells = ToolGrid.cells(count: apps.count, columns: c, rows: r, in: ToolGrid.content(card).size)
        return cells.firstIndex { $0.contains(local) }.map { apps[$0] }
    }

    var body: some View {
        let apps = Self.apps(for: size)
        let (c, r) = Self.shape(size)
        let area = ToolGrid.content(card).size
        let cells = ToolGrid.cells(count: apps.count, columns: c, rows: r, in: area)
        if apps.isEmpty {
            VStack(alignment: .leading, spacing: unit * 0.06) {
                Image(systemName: "square.grid.2x2").font(.system(size: unit * 0.24))
                Spacer(minLength: 0)
                Text(String(localized: "打开几个 App 后会显示在这里")).font(.system(size: unit * 0.12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let icons = WidgetHost.model?.catalog.icons ?? [:]
            let named = size == .large
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(apps, cells)), id: \.0.id) { app, cell in
                    let side = min(cell.width, cell.height) * (named ? 0.62 : 0.84)
                    VStack(spacing: unit * 0.04) {
                        if let icon = icons[app.id] {
                            Image(decorative: icon, scale: 2).resizable().interpolation(.high)
                                .frame(width: side, height: side)
                        } else {
                            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(.primary.opacity(0.12))
                                .frame(width: side * 0.8, height: side * 0.8)
                                .frame(width: side, height: side)
                        }
                        if named {
                            Text(app.name).font(.system(size: unit * 0.1)).lineLimit(1).opacity(0.85)
                        }
                    }
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: cell.minX, y: cell.minY)
                }
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
        }
    }
}

// MARK: - Timer

struct TimerWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize
    let live: Bool

    static let presets = [5, 15, 25, 45]

    enum Hit: Equatable { case toggle, preset(Int) }

    /// Where the ring and the length buttons sit, in content coordinates.
    static func layout(_ size: WidgetItem.Size, card: CGSize) -> (ring: CGRect, presets: [CGRect]) {
        let area = ToolGrid.content(card).size
        switch size {
        case .small:
            return (CGRect(origin: .zero, size: area), [])
        case .medium:
            let ring = CGRect(x: 0, y: 0, width: area.height, height: area.height)
            let rest = CGSize(width: area.width - area.height - area.height * 0.2, height: area.height)
            let gap = area.height * 0.08
            let cells = ToolGrid.cells(count: 4, columns: 2, rows: 2, in: rest, gap: gap)
                .map { $0.offsetBy(dx: area.width - rest.width, dy: 0) }
            return (ring, cells)
        case .large:
            let row = area.height * 0.17
            let gap = area.height * 0.05
            let ring = CGRect(x: 0, y: 0, width: area.width, height: area.height - row - gap * 2)
            let cells = ToolGrid.cells(count: 4, columns: 4, rows: 1, in: CGSize(width: area.width, height: row), gap: gap)
                .map { $0.offsetBy(dx: 0, dy: area.height - row) }
            return (ring, cells)
        }
    }

    static func hit(_ point: CGPoint, size: WidgetItem.Size, card: CGSize) -> Hit? {
        let local = ToolGrid.local(point, card: card)
        let (_, presets) = layout(size, card: card)
        if let i = presets.firstIndex(where: { $0.contains(local) }) { return .preset(Self.presets[i]) }
        return .toggle
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 0.5 : 3600)) { context in
            let t = WidgetStore.shared.timer(id)
            let now = context.date
            let (ring, presets) = Self.layout(size, card: card)
            ZStack(alignment: .topLeading) {
                dial(t, now: now, side: min(ring.width, ring.height))
                    .frame(width: ring.width, height: ring.height)
                    .offset(x: ring.minX, y: ring.minY)
                ForEach(Array(presets.enumerated()), id: \.offset) { i, cell in
                    let minutes = Self.presets[i]
                    let chosen = t.minutes == minutes
                    RoundedRectangle(cornerRadius: min(cell.height, cell.width) * 0.3, style: .continuous)
                        .fill(chosen ? AnyShapeStyle(Color.orange.opacity(0.9)) : AnyShapeStyle(.primary.opacity(0.12)))
                        .overlay {
                            Text(String(localized: "\(minutes) 分钟"))
                                .font(.system(size: unit * 0.12, weight: .semibold))
                                .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        }
                        .frame(width: cell.width, height: cell.height)
                        .offset(x: cell.minX, y: cell.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func dial(_ t: WidgetStore.TimerState, now: Date, side: CGFloat) -> some View {
        let left = t.remaining(at: now)
        let finished = t.isFinished(at: now)
        let fraction = t.total > 0 ? left / t.total : 0
        let line = side * 0.075
        return ZStack {
            Circle().stroke(.primary.opacity(0.15), lineWidth: line)
            Circle().trim(from: 0, to: finished ? 1 : max(0.001, fraction))
                .stroke(finished ? Color.green : Color.orange, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: side * 0.02) {
                if finished {
                    Image(systemName: "checkmark").font(.system(size: side * 0.16, weight: .bold)).foregroundStyle(.green)
                    Text(String(localized: "时间到")).font(.system(size: side * 0.1, weight: .semibold))
                } else {
                    Text(Self.clock(left))
                        .font(.system(size: side * 0.2, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Label(t.isRunning ? String(localized: "暂停") : t.left != nil ? String(localized: "继续") : String(localized: "开始"),
                          systemImage: t.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: side * 0.08, weight: .medium))
                        .opacity(0.65)
                }
            }
        }
        .padding(line / 2)
        .frame(width: side, height: side)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Quick actions

enum QuickAction: String, CaseIterable {
    case lock, screenshot, darkMode, mute, displaySleep, sleep, keepAwake, emptyTrash

    var title: String {
        switch self {
        case .lock: String(localized: "锁屏")
        case .screenshot: String(localized: "截屏")
        case .darkMode: String(localized: "深色模式")
        case .mute: String(localized: "静音")
        case .displaySleep: String(localized: "关闭显示器")
        case .sleep: String(localized: "睡眠")
        case .keepAwake: String(localized: "保持唤醒")
        case .emptyTrash: String(localized: "清空废纸篓")
        }
    }

    var symbol: String {
        switch self {
        case .lock: "lock.fill"
        case .screenshot: "camera.viewfinder"
        case .darkMode: "circle.lefthalf.filled"
        case .mute: "speaker.slash.fill"
        case .displaySleep: "display"
        case .sleep: "moon.zzz.fill"
        case .keepAwake: "cup.and.heat.waves.fill"
        case .emptyTrash: "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .lock: .blue
        case .screenshot: .teal
        case .darkMode: .indigo
        case .mute: .pink
        case .displaySleep: .cyan
        case .sleep: .purple
        case .keepAwake: .orange
        case .emptyTrash: .red
        }
    }

    /// Leaves the launcher first: the action is about the screen or the whole Mac.
    var closesLauncher: Bool { [.lock, .screenshot, .displaySleep, .sleep].contains(self) }
}

@MainActor @Observable
final class QuickActions {
    static let shared = QuickActions()

    private(set) var dark = QuickActions.systemIsDark()
    private(set) var muted = false
    private(set) var keepingAwake = false
    /// Emptying the Trash takes a second click within a few seconds.
    private(set) var trashArmed = false
    @ObservationIgnored private var caffeinate: Process?
    @ObservationIgnored private var disarm: DispatchWorkItem?

    func isOn(_ action: QuickAction) -> Bool {
        switch action {
        case .darkMode: dark
        case .mute: muted
        case .keepAwake: keepingAwake
        case .emptyTrash: trashArmed
        default: false
        }
    }

    func refresh() {
        dark = Self.systemIsDark()
        Self.osascript("output muted of (get volume settings)") { [weak self] out in self?.muted = out == "true" }
    }

    func perform(_ action: QuickAction) {
        switch action {
        case .lock:
            Self.lockScreen()
        case .screenshot:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        case .darkMode:
            dark.toggle()
            Self.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode") { [weak self] _ in
                self?.dark = Self.systemIsDark()
            }
        case .mute:
            muted.toggle()
            Self.osascript("set volume output muted (not (output muted of (get volume settings)))\noutput muted of (get volume settings)") { [weak self] out in
                self?.muted = out == "true"
            }
        case .displaySleep:
            Self.run("/usr/bin/pmset", ["displaysleepnow"])
        case .sleep:
            Self.run("/usr/bin/pmset", ["sleepnow"])
        case .keepAwake:
            if let caffeinate {
                caffeinate.terminate()
                self.caffeinate = nil
                keepingAwake = false
            } else {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                p.arguments = ["-di", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
                p.terminationHandler = { _ in Task { @MainActor in QuickActions.shared.caffeinateEnded(p) } }
                if (try? p.run()) != nil {
                    caffeinate = p
                    keepingAwake = true
                }
            }
        case .emptyTrash:
            disarm?.cancel()
            if trashArmed {
                trashArmed = false
                Self.osascript("tell application \"Finder\" to empty trash") { _ in }
            } else {
                trashArmed = true
                let work = DispatchWorkItem { [weak self] in self?.trashArmed = false }
                disarm = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }
        }
    }

    private func caffeinateEnded(_ p: Process) {
        guard caffeinate === p else { return }
        caffeinate = nil
        keepingAwake = false
    }

    private static func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        try? p.run()
    }

    private static func osascript(_ script: String, done: @escaping @MainActor (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in done(out) }
        }
        try? p.run()
    }

    /// The same as  › Lock Screen.
    private static func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        unsafeBitCast(symbol, to: Lock.self)()
    }
}

struct ActionsWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize

    static func actions(_ size: WidgetItem.Size) -> [QuickAction] {
        size == .small ? [.lock, .screenshot, .darkMode, .mute] : QuickAction.allCases
    }

    static func shape(_ size: WidgetItem.Size) -> (columns: Int, rows: Int) {
        switch size {
        case .small: (2, 2)
        case .medium: (4, 2)
        case .large: (2, 4)
        }
    }

    static func gap(_ card: CGSize) -> CGFloat { min(card.width, card.height) * 0.05 }

    static func action(at point: CGPoint, size: WidgetItem.Size, card: CGSize) -> QuickAction? {
        let list = actions(size)
        let (c, r) = shape(size)
        let local = ToolGrid.local(point, card: card)
        let cells = ToolGrid.cells(count: list.count, columns: c, rows: r, in: ToolGrid.content(card).size, gap: gap(card))
        return cells.firstIndex { $0.contains(local) }.map { list[$0] }
    }

    var body: some View {
        let list = Self.actions(size)
        let (c, r) = Self.shape(size)
        let area = ToolGrid.content(card).size
        let cells = ToolGrid.cells(count: list.count, columns: c, rows: r, in: area, gap: Self.gap(card))
        let state = QuickActions.shared
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(list, cells)), id: \.0) { action, cell in
                tile(action, on: state.isOn(action), cell: cell)
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: cell.minX, y: cell.minY)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .onAppear { state.refresh() }
    }

    private func tile(_ action: QuickAction, on: Bool, cell: CGRect) -> some View {
        let radius = min(cell.width, cell.height) * 0.28
        let title = action == .emptyTrash && on ? String(localized: "再点一次") : action.title
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(on ? AnyShapeStyle(action.tint.opacity(0.9)) : AnyShapeStyle(.primary.opacity(0.1)))
            .overlay {
                if size == .large {
                    HStack(spacing: unit * 0.1) {
                        icon(action, on: on, side: cell.height * 0.5)
                        Text(title).font(.system(size: unit * 0.13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, cell.height * 0.22)
                } else {
                    VStack(spacing: cell.height * 0.06) {
                        icon(action, on: on, side: min(cell.width, cell.height) * 0.42)
                        if size == .medium {
                            Text(title).font(.system(size: unit * 0.09, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                    .padding(cell.height * 0.06)
                }
            }
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .help(action.title)
    }

    private func icon(_ action: QuickAction, on: Bool, side: CGFloat) -> some View {
        ZStack {
            Circle().fill(on ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(action.tint))
            Image(systemName: action.symbol).font(.system(size: side * 0.45, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: side, height: side)
    }
}

// MARK: - To-do

struct TodoWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize
    /// Adding an item: a text field takes the next free line.
    var editing = false

    enum Hit: Equatable { case add, item(String) }

    /// Rows of the card, the title row first.
    static func slots(_ size: WidgetItem.Size) -> Int { size == .large ? 11 : 5 }
    static func columns(_ size: WidgetItem.Size) -> Int { size == .medium ? 2 : 1 }

    /// The title row, the + button in it, and the lines for items, in content coordinates.
    static func layout(_ size: WidgetItem.Size, card: CGSize) -> (header: CGRect, add: CGRect, rows: [CGRect]) {
        let area = ToolGrid.content(card).size
        let slots = slots(size), columns = columns(size)
        let h = area.height / CGFloat(slots)
        let header = CGRect(x: 0, y: 0, width: area.width, height: h)
        let add = CGRect(x: area.width - h * 1.2, y: 0, width: h * 1.2, height: h)
        let gap = area.width * 0.06
        let w = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        var rows: [CGRect] = []
        for c in 0..<columns {
            for r in 1..<slots {
                rows.append(CGRect(x: CGFloat(c) * (w + gap), y: CGFloat(r) * h, width: w, height: h))
            }
        }
        return (header, add, rows)
    }

    /// Open items first, done ones after, each in the order they were added.
    static func ordered(_ list: [WidgetStore.Todo]) -> [WidgetStore.Todo] {
        list.filter { !$0.done } + list.filter(\.done)
    }

    @MainActor static func hit(_ point: CGPoint, id: String, size: WidgetItem.Size, card: CGSize) -> Hit? {
        let local = ToolGrid.local(point, card: card)
        let (header, add, rows) = layout(size, card: card)
        if add.contains(local) { return .add }
        if header.contains(local) { return nil }
        let items = ordered(WidgetStore.shared.todoList(id))
        guard let i = rows.firstIndex(where: { $0.contains(local) }) else { return .add }
        // The last line says how many more there are when the list doesn't fit.
        if items.count > rows.count, i == rows.count - 1 { return nil }
        return i < items.count ? .item(items[i].id) : .add
    }

    var body: some View {
        let list = WidgetStore.shared.todoList(id)
        let items = Self.ordered(list)
        let (header, add, rows) = Self.layout(size, card: card)
        let line = header.height
        let font = Font.system(size: min(unit * 0.14, line * 0.5), weight: .medium)
        // Lines for items; one goes to the "N more" note or to the text field when needed.
        let field = editing ? 1 : 0
        let overflow = items.count + field > rows.count
        let shown = overflow ? max(0, rows.count - 1 - field) : items.count
        ZStack(alignment: .topLeading) {
            HStack(spacing: unit * 0.06) {
                Text(String(localized: "待办")).font(.system(size: min(unit * 0.16, line * 0.6), weight: .bold))
                    .foregroundStyle(.blue)
                let open = list.filter { !$0.done }.count
                if open > 0 {
                    Text("\(open)").font(.system(size: min(unit * 0.13, line * 0.5), weight: .semibold)).opacity(0.5)
                }
                Spacer(minLength: 0)
            }
            .frame(width: header.width - add.width, height: header.height, alignment: .leading)
            Image(systemName: "plus.circle.fill")
                .font(.system(size: line * 0.62))
                .foregroundStyle(.blue)
                .frame(width: add.width, height: add.height, alignment: .trailing)
                .offset(x: add.minX, y: add.minY)

            if items.isEmpty && !editing {
                Text(String(localized: "点 + 添加一项"))
                    .font(font).opacity(0.45)
                    .frame(width: rows[0].width, height: rows[0].height, alignment: .leading)
                    .offset(x: rows[0].minX, y: rows[0].minY)
            }
            ForEach(Array(items.prefix(shown).enumerated()), id: \.element.id) { i, item in
                let r = rows[i]
                HStack(spacing: line * 0.3) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: line * 0.55))
                        .foregroundStyle(item.done ? AnyShapeStyle(.blue) : AnyShapeStyle(.primary.opacity(0.45)))
                    Text(item.text).font(font).lineLimit(1)
                        .strikethrough(item.done)
                        .opacity(item.done ? 0.45 : 1)
                    Spacer(minLength: 0)
                }
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            }
            if editing, shown < rows.count {
                let r = rows[shown]
                HStack(spacing: line * 0.3) {
                    Image(systemName: "circle").font(.system(size: line * 0.55)).opacity(0.45)
                    TodoField(id: id, font: font)
                }
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            }
            if overflow, let r = rows.last {
                Text(String(localized: "还有 \(items.count - shown) 项"))
                    .font(.system(size: min(unit * 0.11, line * 0.45), weight: .medium)).opacity(0.5)
                    .frame(width: r.width, height: r.height, alignment: .leading)
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Typing a new item. Return adds it and leaves the field ready for the next; Esc or a click
/// elsewhere puts it away.
struct TodoField: View {
    let id: String
    let font: Font
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(String(localized: "新的待办"), text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onSubmit {
                WidgetStore.shared.addTodo(text, id)
                text = ""
                DispatchQueue.main.async { focused = true }
            }
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onDisappear { WidgetStore.shared.addTodo(text, id) }
    }
}

// MARK: - Clipboard

/// Text copied lately, while LaunchUS runs. Kept in memory only, and what password managers
/// mark as secret or passing is left out.
@MainActor @Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    static let limit = 20

    private(set) var items: [String] = []
    /// The item just copied back, to show it took.
    private(set) var copied: String?
    @ObservationIgnored private var change = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?

    private static let secret: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType",
    ]

    /// Starts watching once there's a clipboard widget; a check is one integer compare.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.8, repeats: true) { _ in Task { @MainActor in ClipboardHistory.shared.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check() {
        let board = NSPasteboard.general
        guard board.changeCount != change else { return }
        change = board.changeCount
        let types = Set((board.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.secret), let text = board.string(forType: .string) else { return }
        record(text)
    }

    func record(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        change = board.changeCount
        record(text)
        copied = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copied == text { self?.copied = nil }
        }
    }

    func clear() {
        items.removeAll()
    }

    /// One line of it for the card.
    static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    }
}

struct ClipboardWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize

    static func slots(_ size: WidgetItem.Size) -> Int { size == .large ? 10 : size == .medium ? 5 : 4 }

    static func layout(_ size: WidgetItem.Size, card: CGSize) -> (header: CGRect, rows: [CGRect]) {
        let area = ToolGrid.content(card).size
        let slots = slots(size)
        let h = area.height / CGFloat(slots)
        return (CGRect(x: 0, y: 0, width: area.width, height: h),
                (1..<slots).map { CGRect(x: 0, y: CGFloat($0) * h, width: area.width, height: h) })
    }

    @MainActor static func items(_ id: String) -> [String] {
        id.hasPrefix("preview-")
            ? [String(localized: "下午三点在 2 号会议室"), "https://launchus.app", "brew install --cask launchus", String(localized: "收货地址：上海市…")]
            : ClipboardHistory.shared.items
    }

    @MainActor static func item(at point: CGPoint, id: String, size: WidgetItem.Size, card: CGSize) -> String? {
        let local = ToolGrid.local(point, card: card)
        let list = items(id)
        let rows = layout(size, card: card).rows
        return rows.firstIndex { $0.contains(local) }.flatMap { $0 < list.count ? list[$0] : nil }
    }

    var body: some View {
        let history = ClipboardHistory.shared
        let list = Self.items(id)
        let (header, rows) = Self.layout(size, card: card)
        let line = header.height
        let font = Font.system(size: min(unit * 0.13, line * 0.48))
        ZStack(alignment: .topLeading) {
            HStack(spacing: unit * 0.06) {
                Image(systemName: "doc.on.clipboard").font(.system(size: min(unit * 0.14, line * 0.5), weight: .semibold))
                Text(String(localized: "剪贴板")).font(.system(size: min(unit * 0.15, line * 0.56), weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)
            .frame(width: header.width, height: header.height)
            if list.isEmpty {
                Text(String(localized: "拷贝的文字会显示在这里"))
                    .font(font).opacity(0.45)
                    .frame(width: rows[0].width, height: rows[0].height, alignment: .leading)
                    .offset(x: rows[0].minX, y: rows[0].minY)
            }
            ForEach(Array(zip(list, rows).enumerated()), id: \.offset) { _, pair in
                let (text, r) = pair
                let done = history.copied == text
                HStack(spacing: line * 0.25) {
                    Text(done ? String(localized: "已拷贝") : ClipboardHistory.preview(text))
                        .font(font).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, line * 0.25)
                .frame(width: r.width, height: r.height * 0.86)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: line * 0.25, style: .continuous))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { history.start() }
    }
}
