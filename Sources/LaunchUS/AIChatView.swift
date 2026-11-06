import SwiftUI
import AppKit

// MARK: - Card

/// The conversation, under the search field where the apps were.
struct ChatCard: View {
    let chat: ChatSession
    let windowed: Bool
    let height: CGFloat
    let newChat: () -> Void
    let close: () -> Void

    static let width: CGFloat = 680

    private var primary: AnyShapeStyle { windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white) }
    private var secondary: AnyShapeStyle { windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.6)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(windowed ? 1 : 0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if chat.messages.isEmpty, !chat.isStreaming {
                            VStack(spacing: 10) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                Text("想问什么？")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(primary)
                                Text("在上面的输入框里输入，按 ↩ 发送")
                                    .font(.system(size: 12))
                                    .foregroundStyle(secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        }
                        ForEach(chat.messages) { message in
                            ChatBubble(chat: chat, message: message, windowed: windowed,
                                       streaming: chat.isStreaming && message.id == chat.messages.last?.id)
                                .id(message.id)
                        }
                        if chat.isStreaming, !chat.isAsking, chat.messages.last?.role != .assistant || chat.messages.last?.text.isEmpty == true {
                            TypingDots(windowed: windowed)
                        }
                        if let error = chat.error {
                            errorRow(error)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 18)
                }
                .scrollIndicators(.automatic)
                .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            footer
        }
        .frame(width: Self.width, height: height)
        .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.4)),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
                .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.white.opacity(0.12)), in: Circle())
            Text(verbatim: chat.model.isEmpty ? "AI" : chat.model)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary)
                .lineLimit(1)
            Spacer()
            headerButton("square.and.pencil", help: String(localized: "新对话"), action: newChat)
                .disabled(chat.isEmpty)
            headerButton("xmark", help: String(localized: "关闭"), action: close)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondary)
                .frame(width: 26, height: 26)
                .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.white.opacity(0.1)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func errorRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "重试")) { chat.retry() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if chat.isStreaming {
                Button { chat.stop() } label: {
                    Label(String(localized: "停止"), systemImage: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(primary)
            }
            Spacer()
            Text(chat.isAsking ? "↩ 允许 · Esc 拒绝" : chat.isStreaming ? "Esc 停止" : "↩ 发送 · ⌘N 新对话 · Esc 退出")
                .font(.system(size: 11))
                .foregroundStyle(secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.03)) : AnyShapeStyle(.white.opacity(0.04)))
    }
}

private struct ChatBubble: View {
    let chat: ChatSession
    let message: ChatMessage
    let windowed: Bool
    let streaming: Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(verbatim: message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .tool:
            if let call = message.call {
                if message.state == .asking {
                    ApprovalCard(chat: chat, call: call, windowed: windowed)
                } else {
                    ToolRow(call: call, state: message.state, result: message.text, windowed: windowed)
                }
            }
        case .assistant:
            if !message.text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownText(text: message.text, windowed: windowed)
                    if !streaming {
                        CopyButton(text: message.text, windowed: windowed, label: String(localized: "复制"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Paragraphs, lists and headings with inline markdown, and fenced code blocks.
private struct MarkdownText: View {
    let text: String
    let windowed: Bool

    enum Block: Hashable {
        case text(String)
        case heading(String)
        case code(language: String, body: String)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var language = ""
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.text(joined)) }
            paragraph = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language: language, body: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(language: language, body: lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let body):
                    Text(Self.inline(body))
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.92)))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let body):
                    Text(Self.inline(body))
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                        .textSelection(.enabled)
                case .code(let language, let body):
                    CodeBlock(language: language, code: body, windowed: windowed)
                }
            }
        }
    }

    static func inline(_ text: String) -> AttributedString {
        // Bullets read better as "•".
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let indent = line.prefix(while: { $0 == " " })
            let rest = line.dropFirst(indent.count)
            if rest.hasPrefix("- ") || rest.hasPrefix("* ") { return indent + "• " + rest.dropFirst(2) }
            return line
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: lines, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(lines)
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String
    let windowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.55)))
                Spacer()
                CopyButton(text: code, windowed: windowed, label: String(localized: "复制代码"))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.white.opacity(0.06)))
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.9)))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .scrollIndicators(.never)
        }
        .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.black.opacity(0.3)),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CopyButton: View {
    let text: String
    let windowed: Bool
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? String(localized: "已复制") : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.55)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TypingDots: View {
    let windowed: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.7)))
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin((t * 4) - Double(i) * 0.7)))
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityLabel(String(localized: "正在回答"))
    }
}

/// One tool the AI used, as a quiet line in the conversation.
private struct ToolRow: View {
    let call: ToolCall
    let state: ChatMessage.ToolState
    let result: String
    let windowed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch state {
                case .running, .asking: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .font(.system(size: 11))
            .frame(width: 14)
            Image(systemName: AITools.symbol(call.name)).font(.system(size: 11))
            Text(verbatim: AITools.title(call)).lineLimit(1)
            switch state {
            case .denied: Text("已拒绝")
            case .failed: Text(verbatim: result).lineLimit(1).truncationMode(.tail)
            default: EmptyView()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.6)))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.white.opacity(0.07)), in: Capsule())
        .help(result)
    }
}

/// The AI wants to act: say what, and wait for the user.
private struct ApprovalCard: View {
    let chat: ChatSession
    let call: ToolCall
    let windowed: Bool

    private var risky: Bool { AITools.risky.contains(call.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: AITools.symbol(call.name))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(risky ? Color.orange : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background((risky ? Color.orange : Color.accentColor).opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 想要").font(.system(size: 11))
                        .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.6)))
                    Text(verbatim: AITools.title(call)).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                }
            }
            if AITools.isForce(call) {
                Label(String(localized: "强制退出会丢失未存储的内容"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if !risky {
                    Button(String(localized: "本次对话都允许")) { chat.approve(forWholeChat: true) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.65)))
                }
                Spacer()
                Button { chat.deny() } label: {
                    Text("拒绝").padding(.horizontal, 14).padding(.vertical, 6)
                        .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                Button { chat.approve() } label: {
                    Text("允许").padding(.horizontal, 16).padding(.vertical, 6)
                        .background(risky ? Color.orange : Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(14)
        .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder((risky ? Color.orange : Color.accentColor).opacity(0.45), lineWidth: 1))
    }
}
