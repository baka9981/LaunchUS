import AppKit

/// How `LaunchUS --mcp` runs a tool inside the running app and hears back: it opens
/// `launchus://tool?name=…&args=…&reply=…&token=…`, the app runs the tool the way the built-in
/// chat does (`LauncherModel.runLocalTool`) and writes what happened to a reply file, which the
/// MCP process waits for. The token is a secret in a file only this user can read, so a web page
/// or another user's link can't drive these tools.
enum MCPBridge {
    static var folder: URL { LayoutStore.directory.appendingPathComponent("MCP", isDirectory: true) }
    static var tokenURL: URL { folder.appendingPathComponent("token") }

    static func replyURL(_ id: String) -> URL { folder.appendingPathComponent("reply-\(id).json") }

    /// The shared secret, made the first time it's needed.
    static func token(create: Bool) -> String? {
        if let saved = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        // Made only if it isn't there: another MCP process may have just made one, and the first wins.
        let fd = open(tokenURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            _ = token.withCString { Darwin.write(fd, $0, strlen($0)) }
            close(fd)
        }
        return self.token(create: false)
    }

    // MARK: MCP process

    struct Reply: Codable {
        var text: String
        var ok: Bool
    }

    /// Runs a tool in the running LaunchUS (launching it if needed) and returns what it said.
    static func send(_ name: String, _ arguments: [String: Any], timeout: TimeInterval = 20) throws -> String {
        guard let token = token(create: true) else { throw MCPServer.Failure("Couldn't set up the connection to LaunchUS.") }
        let id = UUID().uuidString
        let args = (try? JSONSerialization.data(withJSONObject: arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var parts = URLComponents()
        parts.scheme = URLCommand.scheme
        parts.host = "tool"
        parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "args", value: args),
                            URLQueryItem(name: "reply", value: id), URLQueryItem(name: "token", value: token)]
        guard let url = parts.url else { throw MCPServer.Failure("Couldn't reach LaunchUS.") }
        pruneReplies()

        // This copy if it's running (a plain link might open another one), else the one that is.
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && $0.bundleURL != nil }
        let own = Bundle.main.bundleURL.standardizedFileURL
        let running = copies.first { $0.bundleURL?.standardizedFileURL == own } ?? copies.first
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let failure = Failed()
        NSWorkspace.shared.open([url], withApplicationAt: running?.bundleURL ?? Bundle.main.bundleURL, configuration: config) { _, error in
            if let error { failure.set(error.localizedDescription) }
        }

        let reply = replyURL(id)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: reply), let answer = try? JSONDecoder().decode(Reply.self, from: data) {
                try? FileManager.default.removeItem(at: reply)
                guard answer.ok else { throw MCPServer.Failure(answer.text) }
                return answer.text
            }
            if let message = failure.message { throw MCPServer.Failure("Couldn't reach LaunchUS: \(message)") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw MCPServer.Failure("LaunchUS didn't answer. Make sure this version of LaunchUS is running and isn't showing a dialog.")
    }

    /// Replies nobody waited for any more.
    private static func pruneReplies() {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-600)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where url.lastPathComponent.hasPrefix("reply-") {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old {
                try? fm.removeItem(at: url)
            }
        }
    }

    private final class Failed: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        var message: String? { lock.withLock { text } }
        func set(_ value: String) { lock.withLock { text = value } }
    }

    // MARK: App

    /// Runs a tool asked for by `launchus://tool` and writes the reply. Unknown tokens, reply IDs
    /// and tools are ignored.
    @MainActor
    static func answer(_ request: URLCommand.ToolRequest, model: LauncherModel) {
        guard UUID(uuidString: request.reply) != nil else { return }
        guard let token = token(create: false), !request.token.isEmpty, request.token == token else {
            NSLog("LaunchUS: ignored a tool link without the right token")
            return
        }
        let outcome: LauncherModel.ToolOutcome
        if MCPServer.appToolNames.contains(request.name) {
            outcome = model.runLocalTool(ToolCall(id: request.reply, name: request.name, arguments: request.arguments))
                ?? ("Unknown tool: \(request.name)", false)
        } else {
            outcome = ("Unknown tool: \(request.name)", false)
        }
        write(Reply(text: outcome.text, ok: outcome.ok), to: request.reply)
    }

    static func write(_ reply: Reply, to id: String) {
        guard let data = try? JSONEncoder().encode(reply) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: replyURL(id), options: .atomic)
    }
}
