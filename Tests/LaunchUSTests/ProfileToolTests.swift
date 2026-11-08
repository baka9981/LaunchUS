import Foundation
import Testing
@testable import LaunchUS

/// The AI tools for layouts, their settings and widgets (`MCPServer.appTools`), and the bridge
/// `LaunchUS --mcp` reaches them through. Shares the serialized suite with other users of
/// LayoutStore.directoryOverride.
extension AutoBackupTests {
    @MainActor private func withToolModel(_ body: @MainActor (LauncherModel) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchUSTests-\(UUID().uuidString)")
        let name = "ProfileToolTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        LayoutStore.directoryOverride = dir
        AutoBackup.schedulingEnabled = false
        AIKey.memory = [:]
        defaults.set(true, forKey: "didSeedCategoryTags")
        defer {
            LayoutStore.directoryOverride = nil
            AIKey.memory = nil
            AIKey.profile = ""
            ProfileFolders.current = ""
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        let apps = ["a", "b", "c", "d"].map { app($0) }
        LayoutStore.save(layout: [apps.map { .app($0.id) }])
        let model = LauncherModel(catalog: AppCatalog(apps: apps), settings: Settings(defaults: defaults))
        model.settings.sortOrder = .custom
        model.settings.browseStyle = .paged
        model.catalogChanged()
        try body(model)
    }

    @MainActor private func call(_ model: LauncherModel, _ name: String, _ args: [String: Any] = [:]) -> (text: String, ok: Bool) {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return model.runLocalTool(ToolCall(id: "1", name: name, arguments: json)) ?? ("not handled", false)
    }

    @MainActor @Test func newToolsAreListedWithHints() throws {
        let reply = try #require(MCPServer.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let byName = Dictionary(tools.map { ($0["name"] as! String, $0) }, uniquingKeysWith: { a, _ in a })
        for name in MCPServer.appToolNames { #expect(byName[name] != nil, "\(name) is in tools/list") }
        for name in ["delete_layout", "remove_widget"] {
            let tool = try #require(byName[name])
            #expect((tool["annotations"] as? [String: Bool])?["destructiveHint"] == true)
            #expect((tool["description"] as? String)?.contains("can't be brought back") == true)
        }
        #expect((byName["list_widgets"]?["annotations"] as? [String: Bool])?["readOnlyHint"] == true)
        // The chat asks every time before the destructive ones, and offers the read-only ones in 只能查询.
        #expect(AITools.risky.isSuperset(of: ["delete_layout", "remove_widget"]))
        #expect(AITools.available(.readOnly).map(\.name).contains("get_layout_settings"))
        #expect(!AITools.available(.readOnly).map(\.name).contains("add_widget"))
        #expect(AITools.available(.confirm).map(\.name).contains("add_widget"))
    }

    @MainActor @Test func layoutToolsCreateCopyRenameAndDelete() {
        withToolModel { model in
            #expect(call(model, "create_layout", ["name": "工作", "mode": "window"]).ok)
            #expect(model.currentProfile == "工作")
            #expect(model.settings.displayMode == .window)
            #expect(!call(model, "create_layout", ["name": "工作"]).ok, "names are unique")
            #expect(!call(model, "create_layout", ["name": "default"]).ok)

            // Copying a waiting layout takes its pages, not the ones on screen.
            model.switchProfile("")
            model.settings.columns = 5
            model.layout = [[.app("d"), .app("c"), .app("b"), .app("a")]]
            model.commitLayout()
            model.switchProfile("工作")
            let copied = call(model, "duplicate_layout", ["name": "default", "new_name": "副本"])
            #expect(copied.ok, "\(copied.text)")
            #expect(model.currentProfile == "副本")
            #expect(model.layout.first?.first == .app("d"))
            #expect(model.settings.columns == 5)
            #expect(model.settings.displayMode == .fullScreen)

            #expect(!call(model, "rename_layout", ["name": "default", "new_name": "x"]).ok)
            #expect(call(model, "rename_layout", ["name": "副本", "new_name": "娱乐"]).ok)
            #expect(model.profileNames == ["", "娱乐", "工作"] || model.profileNames == ["", "工作", "娱乐"])

            #expect(!call(model, "delete_layout", ["name": "默认"]).ok, "never the default layout")
            #expect(!call(model, "delete_layout", ["name": "没有"]).ok)
            let deleted = call(model, "delete_layout", ["name": "娱乐"])
            #expect(deleted.ok && deleted.text.contains("default"))
            #expect(model.currentProfile == "")
            #expect(!model.profileNames.contains("娱乐"))
        }
    }

    @MainActor @Test func settingsToolsReadAndChangeByGroup() throws {
        try withToolModel { model in
            model.settings.columns = 7
            let read = call(model, "get_layout_settings", ["group": "display"])
            #expect(read.ok)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(read.text.utf8)) as? [String: Any])
            let display = try #require((json["settings"] as? [String: Any])?["display"] as? [String: Any])
            #expect(display["columns"] as? Int == 7)
            #expect(!read.text.contains("hiddenPhrase"))
            #expect(!call(model, "get_layout_settings", ["group": "hidden"]).ok)

            #expect(call(model, "set_layout_settings", ["group": "display", "values": ["columns": 6, "hideNames": true]]).ok)
            #expect(model.settings.columns == 6 && model.settings.hideNames)
            let clamped = call(model, "set_layout_settings", ["group": "display", "values": ["columns": 99]])
            #expect(clamped.ok && clamped.text.contains("nearest"))
            #expect(model.settings.columns == 10)
            #expect(!call(model, "set_layout_settings", ["group": "display", "values": ["browseStyle": "sideways"]]).ok)
            #expect(model.settings.browseStyle == .paged)
            #expect(!call(model, "set_layout_settings", ["group": "appearance", "values": ["columns": 5]]).ok, "wrong group")
            #expect(!call(model, "set_layout_settings", ["group": "ai", "values": ["aiBaseURL": "https://example.com"]]).ok)
            #expect(!call(model, "set_layout_settings", ["group": "hidden", "values": ["hiddenRequireAuth": false]]).ok)

            // A waiting layout's settings are saved for when it's switched to.
            model.createProfile("工作", mode: .window)
            model.switchProfile("")
            let other = call(model, "set_layout_settings", ["layout": "工作", "group": "display", "values": ["rows": 3]])
            #expect(other.ok, "\(other.text)")
            #expect(model.settings.rows != 3)
            #expect(ProfileSettings.value("rows", in: LayoutProfiles.load().settings["工作"], as: Int.self) == 3)
            model.switchProfile("工作")
            #expect(model.settings.rows == 3)

            // Copying a group from another layout.
            model.switchProfile("")
            model.settings.hideNames = false
            #expect(call(model, "copy_layout_settings", ["from": "工作", "group": "display"]).ok)
            #expect(model.settings.hideNames)
            #expect(model.settings.displayMode == .fullScreen, "the way of showing is never copied")
            #expect(!call(model, "copy_layout_settings", ["from": "default", "group": "display"]).ok)
        }
    }

    @MainActor @Test func widgetToolsAddListAndRemove() {
        withToolModel { model in
            let kinds = call(model, "list_widget_kinds")
            #expect(kinds.text.contains("launchus.clock") && kinds.text.contains("medium (4×2)"))
            #expect(call(model, "list_widgets").text.contains("no widgets"))

            let added = call(model, "add_widget", ["kind": "clock", "size": "4x2", "page": 1, "row": 1, "column": 1])
            #expect(added.ok, "\(added.text)")
            let first = model.layout.first?.first
            guard case .widget(let clock)? = first else { Issue.record("no widget at the start: \(String(describing: first))"); return }
            #expect(clock.kind == "launchus.clock" && clock.size == .medium)
            #expect(call(model, "add_widget", ["kind": "launchus.note", "page": 2]).ok, "one past the last page adds a page")
            #expect(model.layout.count == 2)
            #expect(!call(model, "add_widget", ["kind": "nope"]).ok)
            #expect(!call(model, "add_widget", ["kind": "clock", "size": "huge"]).ok)
            #expect(!call(model, "add_widget", ["kind": "clock", "page": 9]).ok)

            let listed = call(model, "list_widgets").text
            #expect(listed.contains(clock.id) && listed.contains("page 1, row 1, column 1"))
            #expect(call(model, "add_widget", ["kind": "clock"]).ok)
            #expect(!call(model, "remove_widget", ["widget": "clock"]).ok, "two clocks: asks for the ID")
            #expect(call(model, "remove_widget", ["widget": clock.id]).ok)
            #expect(model.location(of: "widget:" + clock.id) == nil)
            #expect(call(model, "remove_widget", ["widget": "便签"]).ok || call(model, "remove_widget", ["widget": "launchus.note"]).ok)
        }
    }

    @MainActor @Test func bridgeAnswersOnlyWithTheToken() throws {
        let link = URL(string: "launchus://tool?name=list_widgets&args=%7B%7D&reply=\(UUID().uuidString)&token=abc")!
        guard case .tool(let request)? = URLCommand(url: link) else { Issue.record("not a tool link"); return }
        #expect(request.name == "list_widgets" && request.arguments == "{}" && request.token == "abc")
        #expect(URLCommand(url: URL(string: "launchus://tool?name=x")!) == nil, "a reply ID is needed")

        try withToolModel { model in
            let token = try #require(MCPBridge.token(create: true))
            #expect(MCPBridge.token(create: true) == token, "made once")
            var wrong = request
            wrong.token = "abc"
            MCPBridge.answer(wrong, model: model)
            #expect(!FileManager.default.fileExists(atPath: MCPBridge.replyURL(request.reply).path))

            var right = request
            right.token = token
            MCPBridge.answer(right, model: model)
            let data = try Data(contentsOf: MCPBridge.replyURL(request.reply))
            let reply = try JSONDecoder().decode(MCPBridge.Reply.self, from: data)
            #expect(reply.ok && reply.text.contains("no widgets"))

            // Only the tools meant for MCP run this way.
            var other = right
            other.name = "move_app"
            other.reply = UUID().uuidString
            MCPBridge.answer(other, model: model)
            let refused = try JSONDecoder().decode(MCPBridge.Reply.self, from: Data(contentsOf: MCPBridge.replyURL(other.reply)))
            #expect(!refused.ok)
        }
    }
}
