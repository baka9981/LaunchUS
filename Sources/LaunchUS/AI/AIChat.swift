import SwiftUI
import AppKit
import Observation
import Security

/// The API a gateway speaks.
enum AIFormat: String, CaseIterable, Codable {
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

/// The gateway's key lives in the keychain, not in preferences. Each layout profile has its own:
/// the default one's is "apiKey", another's "apiKey.<name>".
enum AIKey {
    private static let service = "local.launchus.LaunchUS.ai"
    private static var account: String { account(for: profile) }
    private static var cached: String?
    private static var cachedIsSet: Bool?

    /// The active profile; `LauncherModel` keeps it in step.
    static var profile = "" {
        didSet {
            guard profile != oldValue else { return }
            cached = nil
            cachedIsSet = nil
        }
    }

    private static func account(for profile: String) -> String { profile.isEmpty ? "apiKey" : "apiKey." + profile }

    /// Tests keep keys here, by account, instead of in the keychain.
    static var memory: [String: String]? {
        didSet {
            cached = nil
            cachedIsSet = nil
        }
    }

    private static func query(_ profile: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account(for: profile)]
    }

    /// Reads another profile's key, for copying it.
    private static func value(of profile: String) -> String {
        if profile == self.profile { return value }
        if let memory { return memory[account(for: profile)] ?? "" }
        guard !offKeychain else { return "" }
        var item = query(profile)
        item[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return "" }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func store(_ text: String, for profile: String) {
        if profile == self.profile {
            cached = text
            cachedIsSet = !text.isEmpty
        }
        if memory != nil {
            memory?[account(for: profile)] = text.isEmpty ? nil : text
            return
        }
        guard !offKeychain else { return }
        SecItemDelete(query(profile) as CFDictionary)
        guard !text.isEmpty else { return }
        var item = query(profile)
        item[kSecValueData as String] = Data(text.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Gives `target` the same key as `source`, or none when `source` has none.
    static func copy(from source: String, to target: String) {
        guard source != target else { return }
        store(value(of: source), for: target)
    }

    /// Moves a renamed profile's key without reading it.
    static func rename(_ old: String, to new: String) {
        guard old != new else { return }
        if profile == old || profile == new {
            cached = nil
            cachedIsSet = nil
        }
        if var keys = memory {
            keys[account(for: new)] = keys.removeValue(forKey: account(for: old))
            memory = keys
            return
        }
        guard !offKeychain else { return }
        SecItemDelete(query(new) as CFDictionary)
        SecItemUpdate(query(old) as CFDictionary, [kSecAttrAccount as String: account(for: new)] as CFDictionary)
    }

    static func remove(_ profile: String) {
        guard !profile.isEmpty else { return }
        store("", for: profile)
    }

    /// Debug snapshot and demo runs are signed differently and would ask for keychain access.
    private static var offKeychain: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["LAUNCHUS_SNAPSHOT"] != nil || env["LAUNCHUS_DEMO"] != nil
    }

    /// Whether there is a key, without reading it: menus and search ask this on the main thread,
    /// and reading the secret decrypts it in securityd (or asks for the password, when the app's
    /// signature changed), stalling the launcher. Asking for attributes only does neither.
    static var isSet: Bool {
        if let cached { return !cached.isEmpty }
        if let cachedIsSet { return cachedIsSet }
        if let memory { return memory[account] != nil }
        if offKeychain { return !(ProcessInfo.processInfo.environment["LAUNCHUS_AI_KEY"] ?? "").isEmpty }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true]
        var result: AnyObject?
        let found = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        cachedIsSet = found
        return found
    }

    static var value: String {
        get {
            if let cached { return cached }
            if let memory { return memory[account] ?? "" }
            if offKeychain { return ProcessInfo.processInfo.environment["LAUNCHUS_AI_KEY"] ?? "" }
            var result: AnyObject?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true]
            let text = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
                ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
            cached = text
            return text
        }
        set { store(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: profile) }
    }
}

/// One tool the AI asked to use; `arguments` is its JSON text.
struct ToolCall: Equatable, Sendable, Codable {
    var id: String
    var name: String
    var arguments: String

    var input: [String: Any] {
        (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant, tool }
    enum ToolState: String, Equatable, Codable { case asking, running, done, denied, failed }
    var id = UUID()
    let role: Role
    var text: String
    /// Assistant: the tools it asked to use.
    var toolCalls: [ToolCall] = []
    /// Tool: the call this answers; `text` is what goes back to the AI.
    var call: ToolCall? = nil
    var state: ToolState = .done
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
        if AIClient.errorMessage(json) != nil { throw AIFailure.gateway(status: nil, json: json) }
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

    @MainActor init() { self.init(settings: .shared) }

    @MainActor init(settings: Settings) {
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
        return AIKey.isSet || !settings.aiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Named when the gateway can't be reached.
    var endpointHost: String { Self.endpoint(format: format, base: baseURL)?.host ?? "" }

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
            throw AIFailure.gateway(status: http.statusCode, json: json, body: String(data: data, encoding: .utf8) ?? "",
                                    keyMissing: key.isEmpty)
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
        let keyMissing = key.isEmpty
        let model = model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try built.get())
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count > 64_000 { break } }
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        throw AIFailure.gateway(status: http.statusCode, json: json, body: String(data: data, encoding: .utf8) ?? "",
                                                keyMissing: keyMissing, model: model)
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
    /// Its file in the chat history.
    private(set) var historyID = UUID()
    private(set) var isStreaming = false
    private(set) var error: AIFailure?
    /// The non-risky actions were allowed for the rest of this chat.
    private(set) var allowAll = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    /// Runs the tools that act on the launcher itself; nil hands the call to `MCPServer`.
    @ObservationIgnored var local: (ToolCall) -> (text: String, ok: Bool)? = { _ in nil }

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
        ChatHistory.save(self)
    }

    func reset() {
        stop()
        historyID = UUID()
        messages = []
        error = nil
        allowAll = false
    }

    /// Shown in snapshots and previews.
    func load(_ sample: [ChatMessage], error: AIFailure? = nil) {
        messages = sample
        self.error = error
    }

    /// Picks up a saved chat where it left off.
    func resume(_ saved: ChatHistory.Chat) {
        reset()
        historyID = saved.id
        messages = saved.messages
    }

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
                self.error = AIFailure.from(error, host: client.endpointHost)
                break rounds
            }
            guard !Task.isCancelled, index < messages.count else { return }
            messages[index].toolCalls = calls
            if calls.isEmpty { break }
            for call in calls {
                await perform(call, offered: Set(tools.map(\.name)))
                guard !Task.isCancelled else { return }
            }
        }
        isStreaming = false
        messages.removeAll { $0.role == .assistant && $0.text.isEmpty && $0.toolCalls.isEmpty }
        ChatHistory.save(self)
    }

    /// Runs one call. Only tools that were offered run, so a model can't reach past the access setting.
    private func perform(_ call: ToolCall, offered: Set<String>) async {
        let known = offered.contains(call.name)
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
        if let result = local(call) {
            outcome = result
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
    @MainActor static func test(settings: Settings) async -> Result<String, Error> {
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
