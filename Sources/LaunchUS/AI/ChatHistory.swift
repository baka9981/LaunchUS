import Foundation

/// Past AI chats, one JSON file each under Application Support/LaunchUS/Chats (another layout
/// profile's under `Profiles/<name>/Chats`, see `ProfileFolders`). They stay on
/// this Mac: not in iCloud sync, backups or diagnostics. `Settings.aiHistoryCount` caps how
/// many are kept; 0 keeps none.
enum ChatHistory {
    struct Chat: Codable, Identifiable, Equatable {
        var version = 1
        var id: UUID
        var title: String
        var updated: Date
        var messages: [ChatMessage]
    }

    /// The first part of one, for the list.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let title: String
        let updated: Date
    }

    /// Posted when the list changes.
    static let didChange = Notification.Name("ChatHistory.didChange")

    static var directory: URL { ProfileFolders.url("Chats") }

    private static func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    /// Snapshot runs show a made-up chat; it isn't worth keeping.
    private static var off: Bool { ProcessInfo.processInfo.environment["LAUNCHUS_SNAPSHOT"] != nil }

    /// The first thing asked, on one line.
    static func title(for messages: [ChatMessage]) -> String? {
        guard let first = messages.first(where: { $0.role == .user }) else { return nil }
        let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? first.text
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    /// What's kept: an action left waiting or running can't pick up again, so it reads as stopped.
    static func record(id: UUID, messages: [ChatMessage], now: Date = Date()) -> Chat? {
        guard let title = title(for: messages) else { return nil }
        let settled = messages.compactMap { message -> ChatMessage? in
            if message.role == .assistant, message.text.isEmpty, message.toolCalls.isEmpty { return nil }
            var message = message
            if message.role == .tool, [.asking, .running].contains(message.state) {
                message.state = .denied
                message.text = "Stopped by the user."
            }
            return message
        }
        return Chat(id: id, title: title, updated: now, messages: settled)
    }

    @MainActor static func save(_ session: ChatSession) {
        save(id: session.historyID, messages: session.messages, limit: Settings.shared.aiHistoryCount)
    }

    static func save(id: UUID, messages: [ChatMessage], limit: Int) {
        guard !off, limit > 0, let chat = record(id: id, messages: messages) else { return }
        if let old = load(id), old.messages == chat.messages { return }
        // Dates stay as seconds with fractions, so chats saved a moment apart still sort right.
        let encoder = JSONEncoder()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(chat).write(to: url(id), options: .atomic)
        } catch {
            NSLog("LaunchUS: couldn't save chat: \(error.localizedDescription)")
        }
        prune(keeping: limit)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func load(_ id: UUID) -> Chat? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(Chat.self, from: data)
    }

    /// Newest first.
    static func list() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Entry? in
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))),
                  let chat = load(id) else { return nil }
            return Entry(id: id, title: chat.title, updated: chat.updated)
        }
        .sorted { $0.updated > $1.updated }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Keeps the newest `limit`; 0 removes them all.
    static func prune(keeping limit: Int) {
        guard limit > 0 else { return deleteAll() }
        for entry in list().dropFirst(limit) {
            try? FileManager.default.removeItem(at: url(entry.id))
        }
    }
}
