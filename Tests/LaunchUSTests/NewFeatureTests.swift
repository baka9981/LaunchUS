import Foundation
import Testing
@testable import LaunchUS

struct HomebrewTests {
    @Test func mapsCasksToTheirApps() {
        let json = #"""
        {"formulae":[],"casks":[
          {"token":"libreoffice","artifacts":[{"app":["LibreOffice.app"]},{"zap":[]}]},
          {"token":"renamed","artifacts":[{"app":["Foo.app",{"target":"Bar.app"}]}]},
          {"token":"temurin@21","artifacts":[{"pkg":["x.pkg"]}]}
        ]}
        """#
        let found = Homebrew.apps(inInfo: Data(json.utf8),
                                  versions: ["libreoffice": "26.8.2", "renamed": "2.0,123", "temurin@21": "21"])
        #expect(found["LibreOffice.app"]?.version == "26.8.2")
        #expect(found["LibreOffice.app"]?.token == "libreoffice")
        #expect(found["Bar.app"]?.version == "2.0")
        #expect(found.count == 2)
    }
}

struct CleanupTests {
    @Test func readsBundleIDsFromLibraryNames() {
        #expect(AppCleanup.bundleID(inName: "com.example.Foo.plist") == "com.example.Foo")
        #expect(AppCleanup.bundleID(inName: "com.example.Foo.savedState") == "com.example.Foo")
        #expect(AppCleanup.bundleID(inName: "io.sample.app") == "io.sample.app")
        #expect(AppCleanup.bundleID(inName: "com.apple.Safari.plist") == nil)
        #expect(AppCleanup.bundleID(inName: "Google") == nil)
        #expect(AppCleanup.bundleID(inName: "Some.Folder.Name") == nil)
        #expect(AppCleanup.bundleID(inName: ".GlobalPreferences.plist") == nil)
        #expect(AppCleanup.bundleID(inName: "org.swift.swiftpm") == nil)
        #expect(AppCleanup.bundleID(inName: "group.com.example.Foo") == "com.example.Foo")
        #expect(AppCleanup.bundleID(inName: "ABCDE12345.com.example.Foo") == "com.example.Foo")
        #expect(AppCleanup.bundleID(inName: "com.example.Foo.0A1B2C3D-0000-1111-2222-333344445555.plist") == "com.example.Foo")
    }

    @Test func vendorsWithSomethingInstalledAreNotLeftovers() {
        let installed: Set<String> = ["com.google.chrome"]
        #expect(AppCleanup.isKnown("com.google.Keystone", installed: installed))
        #expect(AppCleanup.isKnown("com.google.Chrome.helper", installed: installed))
        #expect(!AppCleanup.isKnown("com.nonexistent-vendor-zz.Gone", installed: installed))
    }

    @Test func sharedFoldersNeedTheirCreatorGone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func group(_ name: String, creator: String?) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let creator {
                (["MCMMetadataCreator": creator] as NSDictionary)
                    .write(to: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"), atomically: true)
            }
            return url
        }
        let installed: Set<String> = ["com.hegenberg.bettertouchtool"]
        // Named after the developer, made by an installed app: keep.
        let btt = try group("group.com.folivora.BTTShared", creator: "com.hegenberg.BetterTouchTool")
        #expect(AppCleanup.isShared("group.com.folivora.BTTShared", place: "Group Containers", at: btt, installed: installed))
        // Its app is gone: a leftover.
        let gone = try group("group.com.example.gone", creator: "com.example.gone")
        #expect(!AppCleanup.isShared("group.com.example.gone", place: "Group Containers", at: gone, installed: installed))
        // No record of who made it, or a shared folder elsewhere: keep.
        let unknown = try group("ABCDE12345.com.example.x", creator: nil)
        #expect(AppCleanup.isShared("ABCDE12345.com.example.x", place: "Group Containers", at: unknown, installed: installed))
        #expect(AppCleanup.isShared("group.com.example.gone", place: "Application Scripts", at: gone, installed: installed))
        // Ordinary names aren't shared folders.
        #expect(!AppCleanup.isShared("com.example.gone", place: "Containers", at: gone, installed: installed))
    }

    @Test func keepsTheNewestCopyPreferringApplications() {
        let now = Date()
        func copy(_ path: String, _ version: String, _ age: Double) -> DuplicateApp.Copy {
            .init(url: URL(fileURLWithPath: path), version: version, size: 1, modified: now.addingTimeInterval(-age))
        }
        let a = DuplicateApp(bundleID: "x", name: "X", copies: [
            copy("/Users/me/build/X.app", "1.2", 0), copy("/Applications/X.app", "1.2", 100), copy("/Users/me/old/X.app", "1.10", 500)])
        #expect(a.keeper?.url.path == "/Users/me/old/X.app")
        let b = DuplicateApp(bundleID: "y", name: "Y", copies: [copy("/Users/me/build/Y.app", "2", 0), copy("/Applications/Y.app", "2", 100)])
        #expect(b.keeper?.url.path == "/Applications/Y.app")
    }

    @Test func onlyStandaloneCopiesCount() {
        #expect(AppCleanup.isStandalone("/Applications/Foo.app"))
        #expect(AppCleanup.isStandalone(NSHomeDirectory() + "/Applications/Foo.app"))
        #expect(!AppCleanup.isStandalone("/Applications/Xcode.app/Contents/Applications/Simulator.app"))
        #expect(!AppCleanup.isStandalone(NSHomeDirectory() + "/.Trash/Foo.app"))
        #expect(!AppCleanup.isStandalone("/System/Applications/Notes.app"))
    }
}

struct FileSearchTests {
    @Test func skipsLibraryHiddenAndPackageInsides() {
        let home = NSHomeDirectory()
        #expect(FileSearch.isShown(home + "/Documents/Report.pdf"))
        #expect(FileSearch.isShown(home + "/Desktop/Project"))
        #expect(!FileSearch.isShown(home + "/Library/Caches/x.txt"))
        #expect(!FileSearch.isShown(home + "/.config/report"))
        #expect(!FileSearch.isShown(home + "/Pictures/Photos Library.photoslibrary/database/report"))
        #expect(!FileSearch.isShown(home + "/code/web/node_modules/report/index.js"))
    }
}

struct OpenAllCommandTests {
    @Test func parsesTheLink() {
        #expect(URLCommand(url: URL(string: "launchus://openall?name=%E5%B7%A5%E4%BD%9C")!) == .openAll("工作"))
        #expect(URLCommand(url: URL(string: "launchus://group?name=Dev")!) == .openAll("Dev"))
        #expect(URLCommand(url: URL(string: "launchus://openall")!) == nil)
    }
}

struct AIChatTests {
    @Test func buildsEndpoints() {
        #expect(AIClient.endpoint(format: .openAI, base: "https://api.openai.com/v1/")?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(AIClient.endpoint(format: .openAI, base: "http://localhost:11434/v1/chat/completions")?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(AIClient.endpoint(format: .anthropic, base: "https://api.anthropic.com")?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(AIClient.endpoint(format: .anthropic, base: "https://gw.example.com/v1")?.absoluteString == "https://gw.example.com/v1/messages")
    }

    @Test func readsStreamDeltas() throws {
        #expect(try AIClient.delta(in: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#, format: .openAI) == "Hi")
        #expect(try AIClient.delta(in: "data: [DONE]", format: .openAI) == nil)
        #expect(try AIClient.delta(in: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Yo"}}"#, format: .anthropic) == "Yo")
        #expect(try AIClient.delta(in: "event: ping", format: .anthropic) == nil)
        #expect(throws: AIError.self) { try AIClient.delta(in: #"data: {"error":{"message":"bad key"}}"#, format: .openAI) }
    }
}

struct MCPTests {
    @Test func answersTheHandshakeAndListsTools() {
        let reply = MCPServer.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        #expect((reply?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect(MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let tools = (MCPServer.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.count == MCPServer.tools.count)
        let unknown = MCPServer.handle(["jsonrpc": "2.0", "id": 3, "method": "nope"])
        #expect(unknown?["error"] != nil)
    }
}

struct AIToolTests {
    @Test func collectsStreamedToolCalls() throws {
        var openAI = StreamParser(format: .openAI)
        _ = try openAI.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"open_app","arguments":""}}]}}]}"#)
        _ = try openAI.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"app\":"}}]}}]}"#)
        _ = try openAI.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Safari\"}"}}]}}]}"#)
        #expect(openAI.toolCalls == [ToolCall(id: "call_1", name: "open_app", arguments: #"{"app":"Safari"}"#)])

        var anthropic = StreamParser(format: .anthropic)
        _ = try anthropic.feed(#"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"quit_app","input":{}}}"#)
        _ = try anthropic.feed(#"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"app\":\"Notes\"}"}}"#)
        #expect(anthropic.toolCalls.first?.input["app"] as? String == "Notes")
    }

    @Test func sendsResultsAfterTheirCalls() {
        let call = ToolCall(id: "c1", name: "open_app", arguments: #"{"app":"Safari"}"#)
        let messages = [ChatMessage(role: .user, text: "open safari"),
                        ChatMessage(role: .assistant, text: "", toolCalls: [call]),
                        ChatMessage(role: .tool, text: "Opened Safari.", call: call),
                        ChatMessage(role: .assistant, text: "Done.")]
        let openAI = AIClient.encode(messages, format: .openAI, system: "")
        #expect(openAI.map { $0["role"] as? String } == ["user", "assistant", "tool", "assistant"])
        #expect(openAI[2]["content"] as? String == "Opened Safari.")
        let anthropic = AIClient.encode(messages, format: .anthropic, system: "")
        #expect(anthropic.map { $0["role"] as? String } == ["user", "assistant", "user", "assistant"])
        // A call left unanswered still gets a result, so the next request is valid.
        let stopped = AIClient.encode(Array(messages.prefix(2)), format: .openAI, system: "")
        #expect(stopped.last?["content"] as? String == "Cancelled by the user.")
    }

    @Test func guardsActions() {
        let open = ToolCall(id: "1", name: "open_app", arguments: "{}")
        let quit = ToolCall(id: "2", name: "quit_app", arguments: "{}")
        let look = ToolCall(id: "3", name: "list_apps", arguments: "{}")
        #expect(AITools.needsApproval(open, allowAll: false))
        #expect(!AITools.needsApproval(open, allowAll: true))
        #expect(AITools.needsApproval(quit, allowAll: true))
        #expect(!AITools.needsApproval(look, allowAll: false))
        #expect(AITools.available(.off).isEmpty)
        #expect(!AITools.available(.readOnly).contains { $0.name == "open_app" })
    }
}
