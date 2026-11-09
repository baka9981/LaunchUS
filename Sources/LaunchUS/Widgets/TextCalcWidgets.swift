import AppKit
import SwiftUI

// Two small widgets: a line of text (your own, or a quote a day) and a calculator.

// MARK: - Text and daily quote

/// Quotes old enough to belong to everyone: classical Chinese for Chinese, sayings in English otherwise.
enum DailyQuotes {
    struct Quote: Equatable {
        var text: String
        var source: String
    }

    private static let chinese: [(String, String)] = [
        ("千里之行，始于足下。", "老子"),
        ("学而时习之，不亦说乎？", "《论语》"),
        ("知者不惑，仁者不忧，勇者不惧。", "《论语》"),
        ("三人行，必有我师焉。", "《论语》"),
        ("己所不欲，勿施于人。", "《论语》"),
        ("知之为知之，不知为不知，是知也。", "《论语》"),
        ("天行健，君子以自强不息。", "《周易》"),
        ("路漫漫其修远兮，吾将上下而求索。", "屈原"),
        ("不积跬步，无以至千里。", "荀子"),
        ("锲而不舍，金石可镂。", "荀子"),
        ("上善若水，水善利万物而不争。", "老子"),
        ("知人者智，自知者明。", "老子"),
        ("天下大事，必作于细。", "老子"),
        ("吾生也有涯，而知也无涯。", "庄子"),
        ("博学之，审问之，慎思之，明辨之，笃行之。", "《礼记》"),
        ("海内存知己，天涯若比邻。", "王勃"),
        ("长风破浪会有时，直挂云帆济沧海。", "李白"),
        ("天生我材必有用。", "李白"),
        ("会当凌绝顶，一览众山小。", "杜甫"),
        ("欲穷千里目，更上一层楼。", "王之涣"),
        ("行到水穷处，坐看云起时。", "王维"),
        ("采菊东篱下，悠然见南山。", "陶渊明"),
        ("山重水复疑无路，柳暗花明又一村。", "陆游"),
        ("纸上得来终觉浅，绝知此事要躬行。", "陆游"),
        ("问渠那得清如许？为有源头活水来。", "朱熹"),
        ("业精于勤，荒于嬉；行成于思，毁于随。", "韩愈"),
        ("竹杖芒鞋轻胜马，谁怕？一蓑烟雨任平生。", "苏轼"),
        ("但愿人长久，千里共婵娟。", "苏轼"),
        ("人间有味是清欢。", "苏轼"),
        ("沉舟侧畔千帆过，病树前头万木春。", "刘禹锡"),
        ("春风得意马蹄疾，一日看尽长安花。", "孟郊"),
        ("少壮不努力，老大徒伤悲。", "《长歌行》"),
        ("一年之计在于春，一日之计在于晨。", "萧绎"),
        ("黑发不知勤学早，白首方悔读书迟。", "颜真卿"),
        ("莫等闲，白了少年头，空悲切。", "岳飞"),
        ("宝剑锋从磨砺出，梅花香自苦寒来。", "《警世贤文》"),
        ("众里寻他千百度，蓦然回首，那人却在，灯火阑珊处。", "辛弃疾"),
        ("落霞与孤鹜齐飞，秋水共长天一色。", "王勃"),
    ]

    private static let english: [(String, String)] = [
        ("The journey of a thousand miles begins with a single step.", "Lao Tzu"),
        ("Well done is better than well said.", "Benjamin Franklin"),
        ("Lost time is never found again.", "Benjamin Franklin"),
        ("Energy and persistence conquer all things.", "Benjamin Franklin"),
        ("Our life is frittered away by detail. Simplify, simplify.", "Henry David Thoreau"),
        ("Nothing great was ever achieved without enthusiasm.", "Ralph Waldo Emerson"),
        ("Adopt the pace of nature: her secret is patience.", "Ralph Waldo Emerson"),
        ("Write it on your heart that every day is the best day in the year.", "Ralph Waldo Emerson"),
        ("Well begun is half done.", "Aristotle"),
        ("Brevity is the soul of wit.", "William Shakespeare"),
        ("This above all: to thine own self be true.", "William Shakespeare"),
        ("Hope is the thing with feathers.", "Emily Dickinson"),
        ("The best way out is always through.", "Robert Frost"),
        ("Fortune favours the bold.", "Virgil"),
        ("Knowledge is power.", "Francis Bacon"),
        ("Do what you can, with what you have, where you are.", "Theodore Roosevelt"),
        ("Be not afraid of growing slowly; be afraid only of standing still.", "Chinese proverb"),
        ("Dwell on the beauty of life.", "Marcus Aurelius"),
        ("The happiness of your life depends upon the quality of your thoughts.", "Marcus Aurelius"),
        ("Waste no more time arguing what a good man should be. Be one.", "Marcus Aurelius"),
        ("It does not matter how slowly you go as long as you do not stop.", "Confucius"),
        ("Wonder is the beginning of wisdom.", "Socrates"),
        ("Have patience with all things, but first of all with yourself.", "Francis de Sales"),
        ("Little by little, one travels far.", "Proverb"),
        ("Rome wasn't built in a day.", "Proverb"),
        ("A smooth sea never made a skilled sailor.", "Proverb"),
        ("The beginning is the most important part of the work.", "Plato"),
        ("He who has a why to live can bear almost any how.", "Friedrich Nietzsche"),
        ("Act well your part; there all the honour lies.", "Alexander Pope"),
        ("To know that we know what we know, and that we do not know what we do not know, that is true knowledge.", "Confucius"),
    ]

    static var all: [Quote] {
        let language = Locale.preferredLanguages.first ?? "en"
        if language.hasPrefix("zh") {
            let traditional = language.contains("Hant") || ["zh-TW", "zh-HK", "zh-MO"].contains { language.hasPrefix($0) }
            return chinese.map { text, source in
                traditional
                    ? Quote(text: text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text,
                            source: source.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? source)
                    : Quote(text: text, source: source)
            }
        }
        return english.map { Quote(text: $0.0, source: $0.1) }
    }

    /// Today's line, the same all day; `shift` steps on from it.
    static func quote(on date: Date = Date(), shift: Int = 0) -> Quote {
        let list = all
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        // A stride that's coprime with the list length visits every line before repeating.
        let index = ((day * 7 + shift) % list.count + list.count) % list.count
        return list[index]
    }
}

struct TextWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    var editing = false

    private var base: CGFloat {
        switch size {
        case .small: unit * 0.17
        case .medium: unit * 0.2
        case .large: unit * 0.26
        }
    }

    var body: some View {
        let extras = WidgetStore.shared.extras(id)
        let design: Font.Design = extras.serif == true ? .serif : .rounded
        if id.hasPrefix("preview-") || extras.dailyQuote == true {
            TimelineView(.everyMinute) { context in
                let quote = DailyQuotes.quote(on: context.date, shift: extras.quoteShift ?? 0)
                VStack(alignment: .leading, spacing: unit * 0.06) {
                    Image(systemName: "quote.opening").font(.system(size: unit * 0.13, weight: .bold)).opacity(0.5)
                    Text(quote.text)
                        .font(.system(size: base, weight: .semibold, design: design))
                        .lineSpacing(unit * 0.02)
                        .minimumScaleFactor(0.4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    Text(verbatim: "— \(quote.source)").font(.system(size: unit * 0.1, weight: .medium)).opacity(0.6).lineLimit(1)
                }
            }
        } else if editing {
            TextEditorLine(id: id, font: .system(size: base * 0.8, weight: .semibold, design: design))
        } else if let text = extras.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text)
                .font(.system(size: base * 1.2, weight: .semibold, design: design))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: unit * 0.06) {
                Image(systemName: "character.cursor.ibeam").font(.system(size: unit * 0.24))
                Spacer(minLength: 0)
                Text(String(localized: "点一下写点什么")).font(.system(size: unit * 0.12, weight: .medium))
            }
            .opacity(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Typing on the text widget, in place.
private struct TextEditorLine: View {
    let id: String
    let font: Font
    @State private var text: String
    @FocusState private var focused: Bool

    init(id: String, font: Font) {
        self.id = id
        self.font = font
        _text = State(initialValue: WidgetStore.shared.extras(id).text ?? "")
    }

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .multilineTextAlignment(.center)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: text) { _, new in
                var extras = WidgetStore.shared.extras(id)
                extras.text = new
                WidgetStore.shared.setExtras(extras, id, soon: true)
            }
    }
}

// MARK: - Calculator

/// What each calculator widget is in the middle of. Kept in memory only, like a real one.
@MainActor @Observable
final class Calculators {
    static let shared = Calculators()

    struct State: Equatable {
        /// The number being typed or the last result.
        var entry = "0"
        var stored: Double?
        var op: String?
        /// The next digit starts a new number.
        var fresh = true
        /// "12 +", shown above the entry.
        var pending: String { stored.map { "\(Calculators.format($0)) \(op ?? "")" } ?? "" }
    }

    private(set) var states: [String: State] = [:]
    /// The key just pressed, lit for a moment.
    private(set) var lit: (id: String, key: String)?

    func state(_ id: String) -> State { states[id] ?? State() }

    func press(_ key: String, _ id: String) {
        var s = state(id)
        switch key {
        case "0"..."9":
            if s.fresh || s.entry == "0" { s.entry = key } else if s.entry.count < 16 { s.entry += key }
            s.fresh = false
        case ".":
            if s.fresh { s.entry = "0." } else if !s.entry.contains(".") { s.entry += "." }
            s.fresh = false
        case "C":
            s = State()
        case "⌫":
            if Double(s.entry) == nil {
                s.entry = "0"
            } else if !s.fresh {
                s.entry.removeLast()
                if s.entry.isEmpty || s.entry == "-" { s.entry = "0" }
            }
        case "±":
            if s.entry != "0" { s.entry = s.entry.hasPrefix("-") ? String(s.entry.dropFirst()) : "-" + s.entry }
        case "%":
            if let v = Double(s.entry) {
                // 200 + 10 % is 200 + 20, as on a pocket calculator.
                let base = (s.op == "+" || s.op == "−") ? (s.stored ?? 1) : 1
                s.entry = Self.format(v / 100 * base)
                s.fresh = true
            }
        case "+", "−", "×", "÷":
            if let op = s.op, let stored = s.stored, !s.fresh, let v = Double(s.entry) {
                let result = Self.apply(op, stored, v)
                s.entry = Self.format(result)
                s.stored = result
            } else {
                s.stored = Double(s.entry)
            }
            s.op = key
            s.fresh = true
        case "=":
            if let op = s.op, let stored = s.stored, let v = Double(s.entry) {
                s.entry = Self.format(Self.apply(op, stored, v))
            }
            s.stored = nil
            s.op = nil
            s.fresh = true
        default:
            return
        }
        states[id] = s
        lit = (id, key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            if self?.lit?.id == id, self?.lit?.key == key { self?.lit = nil }
        }
    }

    func forget(_ id: String) { states[id] = nil }

    static func apply(_ op: String, _ a: Double, _ b: Double) -> Double {
        switch op {
        case "+": a + b
        case "−": a - b
        case "×": a * b
        case "÷": b == 0 ? .nan : a / b
        default: b
        }
    }

    nonisolated static func format(_ v: Double) -> String {
        guard v.isFinite else { return String(localized: "错误") }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var text = String(format: "%.10g", v)
        if text.contains("e") { return text }
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

struct CalculatorWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize

    /// Tall cards stack the keys under the display; the wide one puts them beside it.
    static func keys(_ size: WidgetItem.Size) -> (keys: [String], columns: Int, rows: Int) {
        if size == .medium {
            return (["7", "8", "9", "÷", "C",
                     "4", "5", "6", "×", "⌫",
                     "1", "2", "3", "−", "%",
                     "0", ".", "±", "+", "="], 5, 4)
        }
        return (["C", "±", "%", "÷",
                 "7", "8", "9", "×",
                 "4", "5", "6", "−",
                 "1", "2", "3", "+",
                 "0", ".", "⌫", "="], 4, 5)
    }

    static func layout(_ size: WidgetItem.Size, card: CGSize) -> (display: CGRect, keys: [CGRect]) {
        let area = ToolGrid.content(card).size
        let (keys, c, r) = keys(size)
        let gap = min(card.width, card.height) * 0.025
        if size == .medium {
            let display = CGRect(x: 0, y: 0, width: area.width * 0.36, height: area.height)
            let pad = CGRect(x: display.maxX + gap * 2, y: 0, width: area.width - display.width - gap * 2, height: area.height)
            let cells = ToolGrid.cells(count: keys.count, columns: c, rows: r, in: pad.size, gap: gap)
            return (display, cells.map { $0.offsetBy(dx: pad.minX, dy: 0) })
        }
        let displayHeight = area.height * (size == .small ? 0.22 : 0.2)
        let display = CGRect(x: 0, y: 0, width: area.width, height: displayHeight)
        let pad = CGSize(width: area.width, height: area.height - displayHeight - gap)
        let cells = ToolGrid.cells(count: keys.count, columns: c, rows: r, in: pad, gap: gap)
        return (display, cells.map { $0.offsetBy(dx: 0, dy: displayHeight + gap) })
    }

    static func key(at point: CGPoint, size: WidgetItem.Size, card: CGSize) -> String? {
        let local = ToolGrid.local(point, card: card)
        let (_, rects) = layout(size, card: card)
        // A click in the gap between two keys still counts for the nearer one.
        let keys = keys(size).keys
        let hit = rects.indices.min { a, b in
            hypot(rects[a].midX - local.x, rects[a].midY - local.y) < hypot(rects[b].midX - local.x, rects[b].midY - local.y)
        }
        guard let hit, rects[hit].insetBy(dx: -4, dy: -4).contains(local) else { return nil }
        return keys[hit]
    }

    var body: some View {
        let store = Calculators.shared
        let state = store.state(id)
        let (display, rects) = Self.layout(size, card: card)
        let keys = Self.keys(size).keys
        let area = ToolGrid.content(card).size
        ZStack(alignment: .topLeading) {
            VStack(alignment: .trailing, spacing: 0) {
                Spacer(minLength: 0)
                Text(verbatim: state.pending).font(.system(size: unit * 0.09, weight: .medium)).opacity(0.55).lineLimit(1)
                Text(verbatim: state.entry)
                    .font(.system(size: unit * (size == .small ? 0.2 : 0.26), weight: .medium, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.35)
            }
            .frame(width: display.width, height: display.height, alignment: .bottomTrailing)
            if WidgetHost.model?.activeCalculator == id {
                // Typing goes here now.
                Image(systemName: "keyboard").font(.system(size: unit * 0.08, weight: .medium)).opacity(0.45)
                    .help(Text(String(localized: "可以用键盘输入，Esc 清零")))
            }
            ForEach(Array(zip(keys, rects)), id: \.0) { key, rect in
                let isOp = ["+", "−", "×", "÷", "="].contains(key)
                let active = state.op == key && state.fresh
                let lit = store.lit?.id == id && store.lit?.key == key
                RoundedRectangle(cornerRadius: min(rect.width, rect.height) * 0.3, style: .continuous)
                    .fill(isOp ? AnyShapeStyle(Color.orange.opacity(active ? 0.6 : 0.95))
                          : ["C", "±", "%", "⌫"].contains(key) ? AnyShapeStyle(.primary.opacity(0.22)) : AnyShapeStyle(.primary.opacity(0.1)))
                    .overlay {
                        Text(verbatim: key)
                            .font(.system(size: min(rect.height * 0.5, unit * 0.16), weight: isOp ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(isOp ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                    .brightness(lit ? 0.25 : 0)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }
}
