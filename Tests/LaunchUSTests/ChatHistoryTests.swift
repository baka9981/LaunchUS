import Foundation
import Testing
@testable import LaunchUS

/// Shares the serialized suite with other users of LayoutStore.directoryOverride.
extension AutoBackupTests {
    private func withChatStore(_ body: () throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchUSTests-\(UUID().uuidString)")
        LayoutStore.directoryOverride = dir
        defer {
            LayoutStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try body()
    }

    @Test func chatHistoryKeepsNewestAndRoundTrips() throws {
        try withChatStore {
            var ids: [UUID] = []
            for n in 1...4 {
                let id = UUID()
                ids.append(id)
                ChatHistory.save(id: id, messages: [ChatMessage(role: .user, text: "question \(n)\nmore"),
                                                    ChatMessage(role: .assistant, text: "answer \(n)")], limit: 3)
                Thread.sleep(forTimeInterval: 0.01)
            }
            let list = ChatHistory.list()
            #expect(list.map(\.id) == ids.reversed().prefix(3).map { $0 }, "newest first, oldest dropped")
            #expect(list.first?.title == "question 4")
            let chat = try #require(ChatHistory.load(ids[3]))
            #expect(chat.messages.map(\.text) == ["question 4\nmore", "answer 4"])
            ChatHistory.delete(ids[3])
            #expect(ChatHistory.list().count == 2)
            ChatHistory.prune(keeping: 0)
            #expect(ChatHistory.list().isEmpty)
        }
    }

    @Test func chatHistorySkipsEmptyAndSettlesActions() throws {
        try withChatStore {
            ChatHistory.save(id: UUID(), messages: [ChatMessage(role: .assistant, text: "hi")], limit: 10)
            ChatHistory.save(id: UUID(), messages: [ChatMessage(role: .user, text: "q")], limit: 0)
            #expect(ChatHistory.list().isEmpty, "nothing asked, or history off")

            let call = ToolCall(id: "1", name: "open_app", arguments: "{}")
            let record = try #require(ChatHistory.record(id: UUID(), messages: [
                ChatMessage(role: .user, text: "open it"),
                ChatMessage(role: .assistant, text: "", toolCalls: [call]),
                ChatMessage(role: .tool, text: "", call: call, state: .asking),
                ChatMessage(role: .assistant, text: ""),
            ]))
            #expect(record.messages.count == 3, "the empty answer goes")
            #expect(record.messages.last?.state == .denied)
            #expect(ChatHistory.title(for: [ChatMessage(role: .user, text: String(repeating: "长", count: 80))])?.count == 61)
        }
    }
}
