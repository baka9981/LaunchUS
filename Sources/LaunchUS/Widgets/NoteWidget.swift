import AppKit
import SwiftUI
import UserNotifications

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
