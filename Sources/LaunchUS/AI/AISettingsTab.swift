import SwiftUI
import AppKit

/// AI: the chat gateway, and the MCP server that lets AI tools drive LaunchUS.
struct AITab: View {
    @Bindable var settings: Settings
    /// Only what's typed here. A saved key is never read just to show the tab: reading the secret
    /// asks for keychain access whenever the app's signature changed. It's read when it's used.
    @State private var key = ""
    @State private var keySaved = AIKey.isSet
    @State private var testing = false
    @State private var testResult: Result<String, Error>?
    /// Kept from the last 获取, so the menu is there next time.
    @State private var models: [String] = UserDefaults.app.stringArray(forKey: "aiModelList") ?? []
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var savedChats = ChatHistory.list().count
    @State private var confirmingClear = false

    private var configured: Bool {
        !settings.aiModel.trimmingCharacters(in: .whitespaces).isEmpty
            && (keySaved || !settings.aiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: String(localized: "网关")) {
                Card {
                    Row(title: String(localized: "接口格式"), info: String(localized: "大多数网关和本地模型（如 Ollama、LM Studio、OpenRouter）用 OpenAI 兼容格式")) {
                        MenuPicker(selection: $settings.aiFormat, options: AIFormat.allCases, title: \.title)
                    }
                    Row(title: String(localized: "地址"), subtitle: String(localized: "留空使用官方地址")) {
                        TextField(settings.aiFormat.defaultBaseURL, text: $settings.aiBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    Row(title: String(localized: "API 密钥"), subtitle: String(localized: "保存在钥匙串中")) {
                        HStack(spacing: 6) {
                            SecureField(keySaved ? "••••••••••••" : String(localized: "未设置"), text: $key)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: keySaved ? 200 : 260)
                                .onChange(of: key) { _, value in
                                    // Typing replaces the saved key; emptying the field removes it.
                                    AIKey.value = value
                                    keySaved = !value.isEmpty
                                    testResult = nil
                                }
                            if keySaved && key.isEmpty {
                                Button(String(localized: "清除")) {
                                    AIKey.value = ""
                                    keySaved = false
                                    testResult = nil
                                }
                                .frame(width: 54)
                            }
                        }
                    }
                    Row(title: String(localized: "模型"), subtitle: fetchError ?? (models.isEmpty ? String(localized: "点「获取」列出网关提供的模型") : String(localized: "共 \(models.count) 个模型"))) {
                        HStack(spacing: 6) {
                            TextField(settings.aiFormat.modelPlaceholder, text: $settings.aiModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            if !models.isEmpty {
                                Menu {
                                    ForEach(models, id: \.self) { name in
                                        Button { settings.aiModel = name } label: {
                                            if name == settings.aiModel { Label(name, systemImage: "checkmark") } else { Text(verbatim: name) }
                                        }
                                    }
                                } label: { Image(systemName: "chevron.up.chevron.down") }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help(String(localized: "选择模型"))
                            }
                            Button(fetching ? String(localized: "获取中…") : String(localized: "获取")) { fetchModels() }
                                .fixedSize()
                                .layoutPriority(1)
                                .disabled(fetching || (!keySaved && settings.aiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty))
                        }
                    }
                }
                Card {
                    Row(title: String(localized: "让 AI 操作这个方案"),
                        subtitle: settings.aiToolAccess.detail) {
                        MenuPicker(selection: $settings.aiToolAccess, options: AIToolAccess.allCases, title: \.title)
                    }
                }
                Card {
                    Row(title: String(localized: "对话记录"), subtitle: settings.aiHistoryCount > 0
                            ? String(localized: "保留最近 \(settings.aiHistoryCount) 段对话，只存在这台 Mac 上")
                            : String(localized: "已关闭，对话关掉就没了")) {
                        HStack(spacing: 10) {
                            Stepper(settings.aiHistoryCount > 0 ? String(localized: "\(settings.aiHistoryCount) 段") : String(localized: "关"),
                                    value: $settings.aiHistoryCount, in: 0...200, step: 10)
                                .monospacedDigit()
                            Button(String(localized: "全部删除…")) { confirmingClear = true }
                                .disabled(savedChats == 0)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: ChatHistory.didChange)) { _ in savedChats = ChatHistory.list().count }
                .confirmationDialog(String(localized: "删除所有对话记录？"), isPresented: $confirmingClear) {
                    Button(String(localized: "全部删除"), role: .destructive) { ChatHistory.deleteAll() }
                } message: {
                    Text("删除后无法恢复。")
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("系统提示词").font(.system(size: 13))
                        Text("每次对话开头发给 AI，可留空").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextEditor(text: $settings.aiSystemPrompt)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 64)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
                    }
                    .padding(14)
                }
                HStack(spacing: 10) {
                    Button(testing ? String(localized: "正在测试…") : String(localized: "测试连接")) { test() }
                        .disabled(!configured || testing)
                    testStatus
                    Spacer()
                }
                .padding(.leading, 4)
                .onChange(of: settings.aiModel) { _, _ in testResult = nil }
                .onChange(of: settings.aiBaseURL) { _, _ in testResult = nil }
                .onChange(of: settings.aiFormat) { _, _ in testResult = nil; clearModels() }
                .onChange(of: settings.aiBaseURL) { _, _ in clearModels() }
            }
        }
    }

    @ViewBuilder private var testStatus: some View {
        switch testResult {
        case .success(let answer):
            Label(answer.isEmpty ? String(localized: "连接成功") : String(localized: "连接成功：\(answer)"),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.system(size: 12)).lineLimit(1)
        case .failure(let error):
            Label(AIFailure.from(error).localizedDescription, systemImage: "xmark.octagon.fill")
                .help(AIFailure.from(error).hasDetail ? AIFailure.from(error).detail : "")
                .foregroundStyle(.red).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
        case nil:
            if !configured {
                Text("填好模型和密钥后可测试").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func clearModels() {
        models = []
        UserDefaults.app.removeObject(forKey: "aiModelList")
    }

    private func fetchModels() {
        fetching = true
        fetchError = nil
        let client = AIClient(settings: settings)
        Task {
            do {
                models = try await client.models()
                UserDefaults.app.set(models, forKey: "aiModelList")
                if settings.aiModel.trimmingCharacters(in: .whitespaces).isEmpty, let first = models.first { settings.aiModel = first }
            } catch {
                fetchError = AIFailure.from(error).localizedDescription
            }
            fetching = false
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            let result = await ChatSession.test(settings: settings)
            testing = false
            testResult = result
        }
    }
}

/// How to add LaunchUS to Claude Code, Codex, Claude Desktop, Cursor and other MCP clients.
struct MCPSection: View {
    private enum Client: CaseIterable {
        case claude, codex, other
        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .other: String(localized: "其他客户端")
            }
        }
    }
    @State private var client = Client.claude

    private var executable: String {
        Bundle.main.executablePath ?? "/Applications/LaunchUS.app/Contents/MacOS/LaunchUS"
    }
    private var command: String { "claude mcp add launchus -- \"\(executable)\" --mcp" }
    private var codexCommand: String { "codex mcp add launchus -- \"\(executable)\" --mcp" }
    /// The same, written into Codex's `~/.codex/config.toml` by hand (the Codex app and IDE
    /// extension read it too).
    private var codexToml: String {
        let path = executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        [mcp_servers.launchus]
        command = "\(path)"
        args = ["--mcp"]
        """
    }
    private var json: String {
        """
        {
          "mcpServers": {
            "launchus": {
              "command": "\(executable)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        SettingsSection(title: "MCP") {
            Text("让 Claude、Codex、Cursor 等 AI 工具搜索和打开 App、退出 App、打开文件夹或分组、切换布局。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
            Picker("", selection: $client) {
                ForEach(Client.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Card {
                switch client {
                case .claude:
                    snippet(title: String(localized: "在终端里运行"), text: command)
                case .codex:
                    snippet(title: String(localized: "在终端里运行"), text: codexCommand)
                    snippet(title: String(localized: "或者写进 ~/.codex/config.toml"), text: codexToml)
                case .other:
                    snippet(title: String(localized: "写进客户端的 MCP 配置（Claude Desktop、Cursor 等）"), text: json)
                }
            }
            Text("可用工具：search_apps、list_apps、open_app、quit_app、running_apps、list_folders、open_folder、open_group、show_launcher、search、list_layouts、switch_layout")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
    }

    private func snippet(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                SnippetCopyButton(text: text)
            }
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
    }
}

private struct SnippetCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? String(localized: "已复制") : String(localized: "复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
    }
}
