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
            if let key = ProcessInfo.processInfo.environment["LAUNCHUS_AI_KEY"],
               ProcessInfo.processInfo.environment["LAUNCHUS_SNAPSHOT"] != nil {
                return key
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

/// One tool the AI asked to use; `arguments` is its JSON text.
struct ToolCall: Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String

    var input: [String: Any] {
        (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, tool }
    enum ToolState: Equatable { case asking, running, done, denied, failed }
    let id = UUID()
    let role: Role
    var text: String
    /// Assistant: the tools it asked to use.
    var toolCalls: [ToolCall] = []
    /// Tool: the call this answers; `text` is what goes back to the AI.
    var call: ToolCall? = nil
    var state: ToolState = .done
}

/// How far the chat may act on LaunchUS.
enum AIToolAccess: String, CaseIterable {
    case off, readOnly, confirm

    var title: String {
        switch self {
        case .off: String(localized: "关闭")
        case .readOnly: String(localized: "只能查询")
        case .confirm: String(localized: "操作前确认")
        }
    }

    var detail: String {
        switch self {
        case .off: String(localized: "AI 只聊天，不碰你的 App")
        case .readOnly: String(localized: "可以搜索和查看 App、文件夹、布局，不能打开或退出")
        case .confirm: String(localized: "查询直接进行；打开 App、切换布局等每次先问你，退出 App 总要确认")
        }
    }
}

/// The MCP tools the built-in chat may use, and how each is shown and guarded.
enum AITools {
    /// Run without asking.
    static let readOnly: Set<String> = ["search_apps", "list_apps", "running_apps", "list_folders", "list_layouts"]
    /// Asked first, unless allowed for the whole chat.
    static let actions: Set<String> = ["open_app", "open_group", "switch_layout", "quit_app"]
    /// Asked every time.
    static let risky: Set<String> = ["quit_app"]

    static let context = """
        You are the assistant inside LaunchUS, the user's Mac app launcher. Use the tools to look up \
        and act on the user's apps, folders and layouts when that helps; actions are shown to the user, \
        who may approve or decline them. If an action is declined, accept it. Keep answers short and \
        answer in the user's language.
        """

    static func available(_ access: AIToolAccess) -> [MCPServer.Tool] {
        let names: Set<String> = switch access {
        case .off: []
        case .readOnly: readOnly
        case .confirm: readOnly.union(actions)
        }
        return MCPServer.tools.filter { names.contains($0.name) }
    }

    static func needsApproval(_ call: ToolCall, allowAll: Bool) -> Bool {
        actions.contains(call.name) && (risky.contains(call.name) || !allowAll)
    }

    static func isForce(_ call: ToolCall) -> Bool { call.name == "quit_app" && call.input["force"] as? Bool == true }

    static func title(_ call: ToolCall) -> String {
        let input = call.input
        let app = input["app"] as? String ?? ""
        let name = input["name"] as? String ?? ""
        switch call.name {
        case "search_apps": return String(localized: "搜索 App「\(input["query"] as? String ?? "")」")
        case "list_apps": return String(localized: "查看 App 列表")
        case "running_apps": return String(localized: "查看正在运行的 App")
        case "list_folders": return String(localized: "查看文件夹")
        case "list_layouts": return String(localized: "查看布局")
        case "open_app": return String(localized: "打开「\(app)」")
        case "open_group": return String(localized: "打开「\(name)」里的所有 App")
        case "switch_layout": return String(localized: "切换到布局「\(name)」")
        case "quit_app": return isForce(call) ? String(localized: "强制退出「\(app)」") : String(localized: "退出「\(app)」")
        default: return call.name
        }
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "search_apps": "magnifyingglass"
        case "list_apps", "list_folders": "square.grid.2x2"
        case "running_apps": "app.badge"
        case "list_layouts", "switch_layout": "rectangle.3.group"
        case "open_app", "open_group": "arrow.up.forward.app"
        case "quit_app": "xmark.app"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Reads a streamed answer line by line: text as it comes, tool calls at the end.
struct StreamParser {
    let format: AIFormat
    private var calls: [Int: ToolCall] = [:]

    init(format: AIFormat) { self.format = format }

    var toolCalls: [ToolCall] { calls.keys.sorted().compactMap { calls[$0] }.filter { !$0.name.isEmpty } }

    mutating func feed(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = AIClient.errorMessage(json) { throw AIError.message(message) }
        switch format {
        case .openAI:
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { return nil }
            for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = part["index"] as? Int ?? calls.count
                let function = part["function"] as? [String: Any] ?? [:]
                var call = calls[index] ?? ToolCall(id: "call_\(index)", name: "", arguments: "")
                if let id = part["id"] as? String, !id.isEmpty { call.id = id }
                if let name = function["name"] as? String, !name.isEmpty { call.name = name }
                call.arguments += function["arguments"] as? String ?? ""
                calls[index] = call
            }
            return delta["content"] as? String
        case .anthropic:
            let index = json["index"] as? Int ?? 0
            switch json["type"] as? String {
            case "content_block_start":
                if let block = json["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                    calls[index] = ToolCall(id: block["id"] as? String ?? "toolu_\(index)", name: block["name"] as? String ?? "", arguments: "")
                }
                return nil
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any] ?? [:]
                if let partial = delta["partial_json"] as? String {
                    calls[index]?.arguments += partial
                    return nil
                }
                return delta["text"] as? String
            default:
                return nil
            }
        }
    }
}

enum StreamEvent: Sendable {
    case text(String)
    case toolCalls([ToolCall])
}

/// Talks to the configured gateway, streaming the answer.
struct AIClient: Sendable {
    let format: AIFormat
    let baseURL: String
    let model: String
    let key: String
    var system: String

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

    /// What a tool call got back; a call left unanswered (stopped) reads as cancelled.
    private static func result(of call: ToolCall, in messages: [ChatMessage]) -> String {
        let text = messages.first { $0.role == .tool && $0.call?.id == call.id }?.text ?? ""
        return text.isEmpty ? "Cancelled by the user." : text
    }

    /// The conversation in the gateway's own shape.
    static func encode(_ messages: [ChatMessage], format: AIFormat, system: String) -> [[String: Any]] {
        switch format {
        case .openAI:
            var out: [[String: Any]] = system.isEmpty ? [] : [["role": "system", "content": system]]
            for message in messages {
                switch message.role {
                case .user:
                    if !message.text.isEmpty { out.append(["role": "user", "content": message.text]) }
                case .assistant:
                    if message.toolCalls.isEmpty {
                        if !message.text.isEmpty { out.append(["role": "assistant", "content": message.text]) }
                    } else {
                        out.append(["role": "assistant", "content": message.text.isEmpty ? NSNull() : message.text,
                                    "tool_calls": message.toolCalls.map {
                                        ["id": $0.id, "type": "function",
                                         "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]]
                                    }])
                        for call in message.toolCalls {
                            out.append(["role": "tool", "tool_call_id": call.id, "content": result(of: call, in: messages)])
                        }
                    }
                case .tool:
                    break  // sent right after the call it answers
                }
            }
            return out
        case .anthropic:
            var out: [[String: Any]] = []
            func add(_ role: String, _ blocks: [[String: Any]]) {
                guard !blocks.isEmpty else { return }
                if let last = out.last, last["role"] as? String == role, let earlier = last["content"] as? [[String: Any]] {
                    out[out.count - 1]["content"] = earlier + blocks
                } else {
                    out.append(["role": role, "content": blocks])
                }
            }
            for message in messages {
                switch message.role {
                case .user:
                    if !message.text.isEmpty { add("user", [["type": "text", "text": message.text]]) }
                case .assistant:
                    let text: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
                    add("assistant", text + message.toolCalls.map {
                        ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input]
                    })
                    add("user", message.toolCalls.map {
                        ["type": "tool_result", "tool_use_id": $0.id, "content": result(of: $0, in: messages)]
                    })
                case .tool:
                    break
                }
            }
            return out
        }
    }

    func request(_ messages: [ChatMessage], tools: [MCPServer.Tool] = [], maxTokens: Int = 4096) throws -> URLRequest {
        guard let url = Self.endpoint(format: format, base: baseURL) else { throw AIError.message(String(localized: "网关地址无效")) }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["model": model, "stream": true]
        switch format {
        case .openAI:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body["messages"] = Self.encode(messages, format: format, system: system)
            if !tools.isEmpty {
                body["tools"] = tools.map {
                    ["type": "function", "function": ["name": $0.name, "description": $0.description,
                                                      "parameters": $0.json["inputSchema"] ?? [:]]]
                }
            }
        case .anthropic:
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["messages"] = Self.encode(messages, format: format, system: "")
            body["max_tokens"] = maxTokens
            if !system.isEmpty { body["system"] = system }
            if !tools.isEmpty {
                body["tools"] = tools.map {
                    ["name": $0.name, "description": $0.description, "input_schema": $0.json["inputSchema"] ?? [:]]
                }
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The models the gateway offers (`GET …/models`), sorted.
    func models() async throws -> [String] {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        for suffix in ["/chat/completions", "/messages"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        if format == .anthropic, !text.hasSuffix("/v1") { text += "/v1" }
        guard let url = URL(string: text + "/models" + (format == .anthropic ? "?limit=1000" : "")) else {
            throw AIError.message(String(localized: "网关地址无效"))
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if format == .anthropic { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        }
        if format == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.message("HTTP \(http.statusCode)" + (json.flatMap(Self.errorMessage).map { " · " + $0 } ?? ""))
        }
        let list = (json?["data"] as? [[String: Any]] ?? json?["models"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String ?? $0["name"] as? String }
        guard !list.isEmpty else { throw AIError.message(String(localized: "网关没有返回模型列表")) }
        return Array(Set(list)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The text of one server-sent event line, if it carries any.
    static func delta(in line: String, format: AIFormat) throws -> String? {
        var parser = StreamParser(format: format)
        return try parser.feed(line)
    }

    static func errorMessage(_ json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] { return error["message"] as? String ?? "\(error)" }
        if let error = json["error"] as? String { return error }
        return nil
    }

    func stream(_ messages: [ChatMessage], tools: [MCPServer.Tool] = []) -> AsyncThrowingStream<StreamEvent, Error> {
        let built = Result { try request(messages, tools: tools) }
        let format = format
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try built.get())
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count > 64_000 { break } }
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        let detail = json.flatMap(Self.errorMessage) ?? String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        throw AIError.message("HTTP \(http.statusCode)" + (detail.isEmpty ? "" : " · " + String(detail.prefix(300))))
                    }
                    var parser = StreamParser(format: format)
                    for try await line in bytes.lines {
                        if let text = try parser.feed(line), !text.isEmpty { continuation.yield(.text(text)) }
                    }
                    if !parser.toolCalls.isEmpty { continuation.yield(.toolCalls(parser.toolCalls)) }
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
    /// The non-risky actions were allowed for the rest of this chat.
    private(set) var allowAll = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    /// Runs the tools that act on the launcher itself (layouts, groups); nil leaves a tool to the MCP server code.
    @ObservationIgnored var local: (ToolCall) -> String? = { _ in nil }

    var model: String { Settings.shared.aiModel }
    var isEmpty: Bool { messages.isEmpty }
    /// An action waits for the user's yes or no.
    var isAsking: Bool { messages.last?.role == .tool && messages.last?.state == .asking }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        messages.append(ChatMessage(role: .user, text: text))
        answer()
    }

    /// Asks again after an error, or for a fresh take on the last answer.
    func retry() {
        guard !isStreaming else { return }
        while let last = messages.last, last.role != .user { messages.removeLast() }
        guard !messages.isEmpty else { return }
        answer()
    }

    func approve(forWholeChat: Bool = false) {
        if forWholeChat { allowAll = true }
        approval?.resume(returning: true)
        approval = nil
    }

    func deny() {
        approval?.resume(returning: false)
        approval = nil
    }

    func stop() {
        task?.cancel()
        task = nil
        approval?.resume(returning: false)
        approval = nil
        isStreaming = false
        for index in messages.indices where messages[index].role == .tool
            && [.asking, .running].contains(messages[index].state) {
            messages[index].state = .denied
            messages[index].text = "Stopped by the user."
        }
        messages.removeAll { $0.role == .assistant && $0.text.isEmpty && $0.toolCalls.isEmpty }
    }

    func reset() {
        stop()
        messages = []
        error = nil
        allowAll = false
    }

    /// Shown in snapshots and previews.
    func load(_ sample: [ChatMessage]) { messages = sample }

    private func answer() {
        error = nil
        isStreaming = true
        let tools = AITools.available(Settings.shared.aiToolAccess)
        var client = AIClient()
        if !tools.isEmpty { client.system = AITools.context + (client.system.isEmpty ? "" : "\n\n" + client.system) }
        task = Task { [weak self] in await self?.run(client, tools: tools) }
    }

    /// Answers, using tools as the AI asks, for a few rounds at most.
    private func run(_ client: AIClient, tools: [MCPServer.Tool]) async {
        rounds: for _ in 0..<8 {
            let history = messages
            messages.append(ChatMessage(role: .assistant, text: ""))
            let index = messages.count - 1
            var calls: [ToolCall] = []
            do {
                for try await event in client.stream(history, tools: tools) {
                    guard !Task.isCancelled, index < messages.count else { return }
                    switch event {
                    case .text(let piece): messages[index].text += piece
                    case .toolCalls(let found): calls = found
                    }
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                break rounds
            }
            guard !Task.isCancelled, index < messages.count else { return }
            messages[index].toolCalls = calls
            if calls.isEmpty { break }
            for call in calls {
                await perform(call)
                guard !Task.isCancelled else { return }
            }
        }
        isStreaming = false
        messages.removeAll { $0.role == .assistant && $0.text.isEmpty && $0.toolCalls.isEmpty }
    }

    private func perform(_ call: ToolCall) async {
        let known = AITools.readOnly.contains(call.name) || AITools.actions.contains(call.name)
        let asks = known && AITools.needsApproval(call, allowAll: allowAll)
        messages.append(ChatMessage(role: .tool, text: "", call: call, state: asks ? .asking : .running))
        let index = messages.count - 1
        guard known else {
            messages[index].state = .failed
            messages[index].text = "Unknown tool: \(call.name)"
            return
        }
        if asks {
            let allowed = await withCheckedContinuation { approval = $0 }
            guard !Task.isCancelled, index < messages.count else { return }
            guard allowed else {
                messages[index].state = .denied
                messages[index].text = "The user declined this action."
                return
            }
            messages[index].state = .running
        }
        let outcome: (text: String, ok: Bool)
        if let text = local(call) {
            outcome = (text, !text.hasPrefix("No "))
        } else {
            outcome = await Task.detached {
                do { return (try MCPServer.call(call.name, json: call.arguments), true) }
                catch { return (error.localizedDescription, false) }
            }.value
        }
        guard !Task.isCancelled, index < messages.count else { return }
        messages[index].text = outcome.text
        messages[index].state = outcome.ok ? .done : .failed
    }

    /// Sends a short message and reports whether the gateway answered.
    static func test(settings: Settings = .shared) async -> Result<String, Error> {
        let client = AIClient(settings: settings)
        do {
            var answer = ""
            for try await event in client.stream([ChatMessage(role: .user, text: "Reply with: OK")]) {
                if case .text(let piece) = event { answer += piece }
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
