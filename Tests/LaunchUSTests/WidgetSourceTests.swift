import Foundation
import Testing
@testable import LaunchUS

struct WidgetSourceTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func lunarFestivals() {
        #expect(Holiday.lunarDate(year: 2027, month: 1, day: 1, calendar: calendar) == day(2027, 2, 6))
        #expect(Holiday.lunarDate(year: 2026, month: 1, day: 1, calendar: calendar) == day(2026, 2, 17))
        #expect(Holiday.lunarDate(year: 2026, month: 8, day: 15, calendar: calendar) == day(2026, 9, 25))
        #expect(Holiday.lunarDate(year: 2026, month: 5, day: 5, calendar: calendar) == day(2026, 6, 19))
    }

    @Test func solarFestivals() {
        #expect(Holiday.easter(2026, calendar: calendar) == day(2026, 4, 5))
        #expect(Holiday.easter(2027, calendar: calendar) == day(2027, 3, 28))
        #expect(Holiday.thanksgiving(2026, calendar: calendar) == day(2026, 11, 26))
        #expect(Holiday.thanksgiving(2027, calendar: calendar) == day(2027, 11, 25))
        #expect(Holiday.qingming(2026, calendar: calendar) == day(2026, 4, 5))
        #expect(Holiday.qingming(2028, calendar: calendar) == day(2028, 4, 4))
    }

    @Test func upcomingIsSortedAndIncludesNewYearsEve() {
        let today = day(2026, 11, 8)
        let list = Holiday.compute(from: today, chinese: true, calendar: calendar)
        #expect(!list.isEmpty)
        #expect(list.allSatisfy { $0.date >= today })
        #expect(list.map(\.date) == list.map(\.date).sorted())
        #expect(list.contains { $0.date == day(2027, 2, 5) })  // 除夕
        #expect(list.first?.days(from: today, calendar: calendar) == 47)  // Christmas
        let western = Holiday.compute(from: today, chinese: false, calendar: calendar)
        #expect(western.first?.date == day(2026, 11, 26))
    }

    @Test func timeProgressStaysInRange() {
        for date in [day(2026, 1, 1), day(2026, 6, 30, hour: 12), day(2026, 12, 31, hour: 23)] {
            for span in TimeProgress.Span.allCases {
                let value = TimeProgress.fraction(span, at: date, calendar: calendar)
                #expect((0...1).contains(value))
            }
        }
        #expect(abs(TimeProgress.fraction(.day, at: day(2026, 3, 3, hour: 12), calendar: calendar) - 0.5) < 0.001)
        #expect(TimeProgress.fraction(.year, at: day(2026, 1, 1), calendar: calendar) < 0.001)
    }

    @MainActor @Test func everyBuiltInWidgetHasAProvider() {
        for widget in BuiltInWidget.allCases {
            let provider = WidgetRegistry.shared.provider(widget.rawValue)
            #expect(provider != nil, "\(widget.rawValue)")
            #expect(provider?.sizes.isEmpty == false)
            #expect(widget.rawValue.hasPrefix("launchus."))
        }
    }
}

@MainActor
struct ToolWidgetTests {
    private func store() -> WidgetStore {
        let store = WidgetStore()
        store.persists = false
        return store
    }

    @Test func timerStartsPausesResumesAndResets() {
        let s = store()
        let id = "test-" + UUID().uuidString
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(s.timer(id).remaining(at: t0) == 25 * 60)
        s.toggleTimer(id, now: t0)
        #expect(s.timer(id).isRunning)
        s.toggleTimer(id, now: t0.addingTimeInterval(60))
        #expect(!s.timer(id).isRunning)
        #expect(s.timer(id).remaining(at: t0.addingTimeInterval(500)) == 24 * 60)
        s.toggleTimer(id, now: t0.addingTimeInterval(600))
        #expect(s.timer(id).remaining(at: t0.addingTimeInterval(660)) == 23 * 60)
        // Past its end it has rung; the next click goes back to the start.
        let late = t0.addingTimeInterval(10_000)
        #expect(s.timer(id).isFinished(at: late))
        s.toggleTimer(id, now: late)
        #expect(!s.timer(id).isRunning)
        #expect(s.timer(id).remaining(at: late) == 25 * 60)
        s.startTimer(id, minutes: 5, now: late)
        #expect(s.timer(id).remaining(at: late) == 5 * 60)
        s.resetTimer(id)
        #expect(!s.timer(id).isRunning)
        s.forget(id)
    }

    @Test func notesKeepTextAndColour() {
        let s = store()
        let id = "test-" + UUID().uuidString
        #expect(s.note(id).text.isEmpty)
        s.setNoteText("买牛奶", id)
        s.setNoteColor(.blue, id)
        #expect(s.note(id) == WidgetStore.Note(text: "买牛奶", color: .blue))
        s.forget(id)
        #expect(s.note(id) == WidgetStore.Note())
        #expect(!s.note("preview-small").text.isEmpty)
    }

    @Test func gridCellsAndHits() {
        let cells = ToolGrid.cells(count: 3, columns: 2, rows: 2, in: CGSize(width: 100, height: 100), gap: 10)
        #expect(cells.count == 3)
        #expect(cells[0] == CGRect(x: 0, y: 0, width: 45, height: 45))
        #expect(cells[2] == CGRect(x: 0, y: 55, width: 45, height: 45))

        let card = CGSize(width: 200, height: 200)
        let inset = ToolGrid.content(card).inset
        #expect(ActionsWidget.action(at: CGPoint(x: inset + 5, y: inset + 5), size: .small, card: card) == .lock)
        #expect(ActionsWidget.action(at: CGPoint(x: 175, y: 175), size: .small, card: card) == .mute)
        // Between two buttons is nothing.
        #expect(ActionsWidget.action(at: CGPoint(x: 100, y: 50), size: .small, card: card) == nil)

        let medium = CGSize(width: 400, height: 200)
        #expect(TimerWidget.hit(CGPoint(x: 60, y: 100), size: .medium, card: medium) == .toggle)
        let presets = TimerWidget.layout(.medium, card: medium).presets
        let first = ToolGrid.content(medium).inset
        #expect(TimerWidget.hit(CGPoint(x: presets[0].midX + first, y: presets[0].midY + first), size: .medium, card: medium) == .preset(5))
        #expect(TimerWidget.hit(CGPoint(x: presets[3].midX + first, y: presets[3].midY + first), size: .medium, card: medium) == .preset(45))
    }

    @Test func markdownBlocks() {
        let text = "# 标题\n## 小标题\n- [ ] 要做\n- [x] 做完\n* 要点\n3. 第三\n> 引用\n---\n\n**粗体** 正文\n#不是标题"
        #expect(Markdown.blocks(text) == [
            .heading(1, "标题"), .heading(2, "小标题"), .task(false, "要做"), .task(true, "做完"), .bullet("要点"),
            .numbered("3", "第三"), .quote("引用"), .rule, .blank, .paragraph("**粗体** 正文"), .paragraph("#不是标题"),
        ])
        #expect(String(Markdown.inline("**粗体** 和 `code`").characters) == "粗体 和 code")
        #expect(Markdown.blocks("<hr>\n<HR />") == [.rule, .rule])
    }

    @Test func todosAddToggleAndClear() {
        let s = store()
        let id = "test-" + UUID().uuidString
        s.addTodo("  ", id)
        #expect(s.todoList(id).isEmpty)
        s.addTodo("一", id)
        s.addTodo("二", id)
        let first = s.todoList(id)[0].id
        s.toggleTodo(first, id)
        #expect(TodoWidget.ordered(s.todoList(id)).map(\.text) == ["二", "一"])
        s.clearDoneTodos(id)
        #expect(s.todoList(id).map(\.text) == ["二"])
        s.forget(id)
        #expect(s.todoList(id).isEmpty)
    }

    @Test func todoHits() {
        let card = CGSize(width: 200, height: 200)
        let id = "test-" + UUID().uuidString
        let (_, add, rows) = TodoWidget.layout(.small, card: card)
        let inset = ToolGrid.content(card).inset
        #expect(rows.count == 4)
        #expect(TodoWidget.hit(CGPoint(x: add.midX + inset, y: add.midY + inset), id: id, size: .small, card: card) == .add)
        // An empty line adds too.
        #expect(TodoWidget.hit(CGPoint(x: rows[2].midX + inset, y: rows[2].midY + inset), id: id, size: .small, card: card) == .add)
        #expect(TodoWidget.layout(.medium, card: CGSize(width: 400, height: 200)).rows.count == 8)
    }

    @Test func clipboardKeepsRecentDistinctText() {
        let history = ClipboardHistory()
        history.record("a")
        history.record("b")
        history.record("a")
        history.record("   ")
        #expect(history.items == ["a", "b"])
        for i in 0..<30 { history.record("\(i)") }
        #expect(history.items.count == ClipboardHistory.limit)
        #expect(ClipboardHistory.preview("第一行\n\n  第二行 ") == "第一行 ⏎ 第二行")
    }

    @Test func timerClock() {
        #expect(TimerWidget.clock(25 * 60) == "25:00")
        #expect(TimerWidget.clock(59.2) == "01:00")
        #expect(TimerWidget.clock(3725) == "1:02:05")
    }
}
