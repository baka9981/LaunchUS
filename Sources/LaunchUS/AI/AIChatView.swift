import SwiftUI
import AppKit

// MARK: - Card

/// The conversation, in the grid's place: header, messages, and the composer at the bottom.
struct ChatCard: View {
    let chat: ChatSession
    let windowed: Bool
    let width: CGFloat
    let height: CGFloat
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    /// ↩ or the send button: sends what's typed (or allows a waiting action).
    let send: () -> Void
    /// A suggestion: sends this text.
    let ask: (String) -> Void
    let openSettings: () -> Void
    let newChat: () -> Void
    let close: () -> Void

    /// The messages' column, so long lines stay readable on a wide card.
    static let column: CGFloat = 780

    @State private var showingHistory = false
    @State private var history: [ChatHistory.Entry] = []
    @State private var confirmingClear = false
    @State private var showingDetail = false
    private var keepsHistory: Bool { Settings.shared.aiHistoryCount > 0 }

    private var primary: AnyShapeStyle { windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white) }
    private var secondary: AnyShapeStyle { windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.62)) }
    private var tertiary: AnyShapeStyle { windowed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white.opacity(0.42)) }
    private var fill: AnyShapeStyle { windowed ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.white.opacity(0.1)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(windowed ? 0.6 : 0.25)
            if showingHistory {
                historyList
            } else {
                conversation
            }
            composer
        }
        .frame(width: width, height: height)
        .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.42)),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(windowed ? 0 : 0.16), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
        .onAppear { history = ChatHistory.list() }
        .onReceive(NotificationCenter.default.publisher(for: ChatHistory.didChange)) { _ in history = ChatHistory.list() }
        .onChange(of: chat.historyID) { _, _ in showingHistory = false }
        .onChange(of: chat.error) { _, _ in showingDetail = false }
        .confirmationDialog(String(localized: "删除所有对话记录？"), isPresented: $confirmingClear) {
            Button(String(localized: "全部删除"), role: .destructive) { ChatHistory.deleteAll() }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AIAvatar(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 助手")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primary)
                if !chat.model.isEmpty {
                    Text(verbatim: chat.model)
                        .font(.system(size: 11.5))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if keepsHistory {
                headerButton(showingHistory ? "bubble.left.and.text.bubble.right" : "clock.arrow.circlepath",
                             help: showingHistory ? String(localized: "回到对话") : String(localized: "对话记录"),
                             selected: showingHistory) {
                    if !showingHistory { history = ChatHistory.list() }
                    withAnimation(.easeOut(duration: 0.18)) { showingHistory.toggle() }
                }
                .disabled(history.isEmpty && !showingHistory)
            }
            headerButton("square.and.pencil", help: String(localized: "新对话")) {
                showingHistory = false
                newChat()
            }
            .disabled(chat.isEmpty)
            headerButton("xmark", help: String(localized: "关闭"), action: close)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func headerButton(_ symbol: String, help: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : secondary)
                .frame(width: 34, height: 34)
                .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if chat.messages.isEmpty, !chat.isStreaming {
                        welcome
                    }
                    ForEach(chat.messages) { message in
                        ChatBubble(chat: chat, message: message, windowed: windowed,
                                   streaming: chat.isStreaming && message.id == chat.messages.last?.id)
                            .id(message.id)
                    }
                    if chat.isStreaming, !chat.isAsking, chat.messages.last?.role != .assistant || chat.messages.last?.text.isEmpty == true {
                        HStack(alignment: .center, spacing: 14) {
                            AIAvatar(size: 28)
                            TypingDots(windowed: windowed)
                        }
                    }
                    if let failure = chat.error {
                        errorCard(failure)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: Self.column)
                .padding(.horizontal, 32).padding(.vertical, 26)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: chat.error) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    /// An empty chat: a greeting, a few things to try, and the last chats.
    private var welcome: some View {
        VStack(spacing: 0) {
            AIAvatar(size: 64)
                .shadow(color: .purple.opacity(0.45), radius: 24)
                .padding(.bottom, 20)
            Text("有什么可以帮你？")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(primary)
            Text("在下面输入问题，按 ↩ 发送")
                .font(.system(size: 13.5))
                .foregroundStyle(secondary)
                .padding(.top, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(suggestions, id: \.text) { item in
                    SuggestionTile(symbol: item.symbol, text: item.text, windowed: windowed) { ask(item.text) }
                }
            }
            .frame(maxWidth: 620)
            .padding(.top, 30)
            if keepsHistory, !history.isEmpty {
                recent.padding(.top, 30)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    /// Ideas to start with; the LaunchUS ones only when the AI may look at the launcher.
    private var suggestions: [(symbol: String, text: String)] {
        let launcher = Settings.shared.aiToolAccess != .off
        return launcher ? [
            ("folder.badge.plus", String(localized: "把游戏都放进一个文件夹")),
            ("chart.bar", String(localized: "我最近最常用哪些 App？")),
            ("sparkle.magnifyingglass", String(localized: "推荐几款好用的截图工具")),
            ("text.bubble", String(localized: "帮我写一段请假的消息")),
        ] : [
            ("sparkle.magnifyingglass", String(localized: "推荐几款好用的截图工具")),
            ("text.bubble", String(localized: "帮我写一段请假的消息")),
            ("lightbulb", String(localized: "用简单的话解释什么是 API")),
            ("globe", String(localized: "把这句话翻译成英文：明天见")),
        ]
    }

    /// The last few chats, under the suggestions.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近的对话")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondary)
                Spacer()
                if history.count > 3 {
                    Button(String(localized: "全部 \(history.count) 段")) { showingHistory = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 2)
            ForEach(history.prefix(3)) { entry in
                HistoryRow(entry: entry, current: false, windowed: windowed,
                           open: { resume(entry.id) }, delete: { ChatHistory.delete(entry.id) })
            }
        }
        .frame(maxWidth: 620)
    }

    private func errorCard(_ failure: AIFailure) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: failure.kind == .offline || failure.kind == .unreachable ? "wifi.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: failure.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(primary)
                if !failure.hint.isEmpty {
                    Text(verbatim: failure.hint)
                        .font(.system(size: 13))
                        .foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showingDetail, failure.hasDetail {
                    Text(verbatim: failure.detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.black.opacity(0.25)),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.top, 2)
                }
                HStack(spacing: 8) {
                    pillButton(String(localized: "重试"), prominent: true) { chat.retry() }
                    if failure.opensSettings {
                        pillButton(String(localized: "打开 AI 设置"), prominent: false, action: openSettings)
                    }
                    if failure.hasDetail {
                        Button(showingDetail ? String(localized: "收起原文") : String(localized: "查看原文")) {
                            withAnimation(.easeOut(duration: 0.15)) { showingDetail.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(secondary)
                        .padding(.leading, 4)
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.orange.opacity(windowed ? 0.08 : 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5))
    }

    private func pillButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : primary)
                .background(prominent ? AnyShapeStyle(Color.accentColor) : fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: History

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text("对话记录")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primary)
                    .padding(.horizontal, 12).padding(.bottom, 12)
                if history.isEmpty {
                    Text("还没有对话记录")
                        .font(.system(size: 13))
                        .foregroundStyle(secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
                ForEach(history) { entry in
                    HistoryRow(entry: entry, current: entry.id == chat.historyID, windowed: windowed,
                               open: { resume(entry.id) }, delete: { ChatHistory.delete(entry.id) })
                }
                if !history.isEmpty {
                    HStack {
                        Text("只保存在这台 Mac 上，最多 \(Settings.shared.aiHistoryCount) 段，可在设置 › AI 里更改")
                            .font(.system(size: 11.5))
                            .foregroundStyle(tertiary)
                        Spacer()
                        Button(String(localized: "全部删除…")) { confirmingClear = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 12).padding(.top, 16)
                }
            }
            .frame(maxWidth: Self.column)
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private func resume(_ id: UUID) {
        showingHistory = false
        guard id != chat.historyID || chat.isEmpty, let saved = ChatHistory.load(id) else { return }
        chat.resume(saved)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if query.isEmpty {
                        Text(chat.isAsking ? "按 ↩ 允许，或输入别的要求…" : chat.isEmpty ? "问点什么…" : "继续问…")
                            .foregroundStyle(tertiary)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $query, axis: .vertical)
                        .accessibilityLabel(String(localized: "给 AI 的消息"))
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .foregroundStyle(primary)
                        .tint(windowed ? Color.accentColor : .white)
                        .focused(focused)
                }
                .font(.system(size: 15))
                .padding(.vertical, 7)
                if chat.isStreaming, !chat.isAsking {
                    roundButton("stop.fill", help: String(localized: "停止"), enabled: true, prominent: false) { chat.stop() }
                } else {
                    roundButton("arrow.up", help: String(localized: "发送"),
                                enabled: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isAsking,
                                prominent: true, action: send)
                }
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            .background(windowed ? AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.7)) : AnyShapeStyle(.white.opacity(0.1)),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(focused.wrappedValue ? Color.accentColor.opacity(0.7) : (windowed ? Color.primary.opacity(0.1) : .white.opacity(0.18)), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onTapGesture { focused.wrappedValue = true }
            Text(chat.isAsking ? "↩ 允许 · Esc 拒绝" : chat.isStreaming ? "Esc 停止" : "↩ 发送 · ⌘N 新对话 · Esc 退出")
                .font(.system(size: 11))
                .foregroundStyle(tertiary)
        }
        .frame(maxWidth: Self.column)
        .padding(.horizontal, 32).padding(.top, 10).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private func roundButton(_ symbol: String, help: String, enabled: Bool, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : primary)
                .frame(width: 34, height: 34)
                .background(prominent ? AnyShapeStyle(Color.accentColor.opacity(enabled ? 1 : 0.35)) : fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The AI's mark: a sparkle on a soft gradient.
struct AIAvatar: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.13, green: 0.75, blue: 0.86)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// One thing to try, in the empty chat.
private struct SuggestionTile: View {
    let symbol: String
    let text: String
    let windowed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                Text(verbatim: text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.9)))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(windowed ? AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05)) : AnyShapeStyle(.white.opacity(hovering ? 0.16 : 0.08)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(windowed ? Color.primary.opacity(0.08) : .white.opacity(0.12), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One saved chat in the list: opens on click, a trash button on hover.
private struct HistoryRow: View {
    let entry: ChatHistory.Entry
    let current: Bool
    let windowed: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left")
                .font(.system(size: 12))
                .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.55)))
            Text(verbatim: entry.title)
                .font(.system(size: 14, weight: current ? .semibold : .regular))
                .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.92)))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if hovering {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.6)))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "删除"))
                .accessibilityLabel(String(localized: "删除"))
            } else {
                Text(entry.updated, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.5)))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background((hovering || current) ? (windowed ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(.white.opacity(0.1))) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: String(localized: "删除"), delete)
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
                Spacer(minLength: 120)
                Text(verbatim: message.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        case .tool:
            if let call = message.call {
                if message.state == .asking {
                    ApprovalCard(chat: chat, call: call, windowed: windowed)
                        .padding(.leading, 42)
                } else {
                    ToolRow(call: call, state: message.state, result: message.text, windowed: windowed)
                        .padding(.leading, 42)
                }
            }
        case .assistant:
            if !message.text.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    AIAvatar(size: 28)
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownText(text: message.text, windowed: windowed)
                        if !streaming {
                            CopyButton(text: message.text, windowed: windowed, label: String(localized: "复制"))
                        }
                    }
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let body):
                    Text(Self.inline(body))
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.92)))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let body):
                    Text(Self.inline(body))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                        .textSelection(.enabled)
                        .padding(.top, 4)
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
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.9)))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .scrollIndicators(.never)
        }
        .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.black.opacity(0.3)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .font(.system(size: 12.5))
        .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.65)))
        .padding(.horizontal, 12).padding(.vertical, 6)
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
