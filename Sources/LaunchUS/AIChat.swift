import SwiftUI
import AppKit
import Observation
import Security

/// The API a gateway speaks.
enum AIFormat: String, CaseIterable {
    case openAI, anthropic

    var title: String {
        switch self {
        case .openAI: String(localized: "OpenAI 兼容")
        case .anthropic: "Anthropic"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com"
        }
    }

    var modelPlaceholder: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .anthropic: "claude-sonnet-5-5"
        }
    }
}

/// The gateway's key lives in the keychain, not in preferences.
enum AIKey {
    private static let service = "local.launchus.LaunchUS.ai"
    private static let account = "apiKey"
    private static var cached: String?

    static var value: String {
        get {
            if let cached { return cached }
            // Debug snapshot runs are signed differently and would ask for keychain access.
            if ProcessInfo.processInfo.environment["LAUNCHUS_SNAPSHOT"] != nil {
                return ProcessInfo.processInfo.environment["LAUNCHUS_AI_KEY"] ?? ""
            }
            var result: AnyObject?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true]
            let text = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
                ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
            cached = text
            return text
        }
        set {
            let text = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cached = text
            guard ProcessInfo.processInfo.environment["LAUNCHUS_SNAPSHOT"] == nil else { return }
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard !text.isEmpty else { return }
            var item = base
            item[kSecValueData as String] = Data(text.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// Talks to the configured gateway, streaming the answer.
struct AIClient: Sendable {
    let format: AIFormat
    let baseURL: String
    let model: String
    let key: String
    let system: String

    @MainActor init(settings: Settings = .shared) {
        format = settings.aiFormat
        let base = settings.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = base.isEmpty ? settings.aiFormat.defaultBaseURL : base
        model = settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        key = AIKey.value
        system = settings.aiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A model is named, and there is a key — or a gateway of one's own that may not need one.
    @MainActor static var isConfigured: Bool {
        let settings = Settings.shared
        guard !settings.aiModel.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !AIKey.value.isEmpty || !settings.aiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func endpoint(format: AIFormat, base: String) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        switch format {
        case .openAI:
            if !text.hasSuffix("/chat/completions") { text += "/chat/completions" }
        case .anthropic:
            if text.hasSuffix("/messages") { break }
            text += text.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        }
        return URL(string: text)
    }

    func request(_ messages: [ChatMessage], maxTokens: Int = 4096) throws -> URLRequest {
        guard let url = Self.endpoint(format: format, base: baseURL) else { throw AIError.message(String(localized: "网关地址无效")) }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let turns = messages.filter { !$0.text.isEmpty }.map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any] = ["model": model, "stream": true]
        switch format {
        case .openAI:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body["messages"] = (system.isEmpty ? [] : [["role": "system", "content": system]]) + turns
        case .anthropic:
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["messages"] = turns
            body["max_tokens"] = maxTokens
            if !system.isEmpty { body["system"] = system }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The text of one server-sent event line, if it carries any.
    static func delta(in line: String, format: AIFormat) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = errorMessage(json) { throw AIError.message(message) }
        switch format {
        case .openAI:
            let choice = (json["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        case .anthropic:
            guard json["type"] as? String == "content_block_delta" else { return nil }
            return (json["delta"] as? [String: Any])?["text"] as? String
        }
    }

    static func errorMessage(_ json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] { return error["message"] as? String ?? "\(error)" }
        if let error = json["error"] as? String { return error }
        return nil
    }

    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try request(messages))
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count > 64_000 { break } }
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        let detail = json.flatMap(Self.errorMessage) ?? String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        throw AIError.message("HTTP \(http.statusCode)" + (detail.isEmpty ? "" : " · " + String(detail.prefix(300))))
                    }
                    for try await line in bytes.lines {
                        if let text = try Self.delta(in: line, format: format), !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

/// One conversation in the launcher.
@MainActor @Observable
final class ChatSession {
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var model: String { Settings.shared.aiModel }
    var isEmpty: Bool { messages.isEmpty }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        messages.append(ChatMessage(role: .user, text: text))
        answer()
    }

    /// Asks again after an error, or for a fresh take on the last answer.
    func retry() {
        guard !isStreaming else { return }
        if messages.last?.role == .assistant { messages.removeLast() }
        guard messages.last?.role == .user else { return }
        answer()
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
        if messages.last?.role == .assistant, messages.last?.text.isEmpty == true { messages.removeLast() }
    }

    func reset() {
        stop()
        messages = []
        error = nil
    }

    /// Shown in snapshots and previews.
    func load(_ sample: [ChatMessage]) { messages = sample }

    private func answer() {
        error = nil
        isStreaming = true
        let history = messages
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        let client = AIClient()
        task = Task { [weak self] in
            do {
                for try await piece in client.stream(history) {
                    guard let self, !Task.isCancelled, index < self.messages.count else { return }
                    self.messages[index].text += piece
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self?.error = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            self.isStreaming = false
            if index < self.messages.count, self.messages[index].text.isEmpty { self.messages.remove(at: index) }
        }
    }

    /// Sends a short message and reports whether the gateway answered.
    static func test(settings: Settings = .shared) async -> Result<String, Error> {
        let client = AIClient(settings: settings)
        do {
            var answer = ""
            for try await piece in client.stream([ChatMessage(role: .user, text: "Reply with: OK")]) {
                answer += piece
                if answer.count > 40 { break }
            }
            return .success(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(error)
        }
    }
}

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
                        ForEach(chat.messages) { message in
                            ChatBubble(message: message, windowed: windowed,
                                       streaming: chat.isStreaming && message.id == chat.messages.last?.id)
                                .id(message.id)
                        }
                        if chat.isStreaming, chat.messages.last?.text.isEmpty ?? true {
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
            Text(chat.isStreaming ? "Esc 停止" : "↩ 发送 · ⌘N 新对话 · Esc 退出")
                .font(.system(size: 11))
                .foregroundStyle(secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.03)) : AnyShapeStyle(.white.opacity(0.04)))
    }
}

private struct ChatBubble: View {
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
