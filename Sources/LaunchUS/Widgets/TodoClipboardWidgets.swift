import AppKit
import SwiftUI
import UserNotifications

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
