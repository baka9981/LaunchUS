import SwiftUI
import AppKit

/// AI: the chat gateway, and the MCP server that lets AI tools drive LaunchUS.
struct AITab: View {
    @Bindable var settings: Settings
    @State private var key = AIKey.value
    @State private var testing = false
    @State private var testResult: Result<String, Error>?

    private var configured: Bool {
        !settings.aiModel.trimmingCharacters(in: .whitespaces).isEmpty
            && (!key.isEmpty || !settings.aiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
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
                        SecureField(String(localized: "未设置"), text: $key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .onChange(of: key) { _, value in AIKey.value = value; testResult = nil }
                    }
                    Row(title: String(localized: "模型")) {
                        TextField(settings.aiFormat.modelPlaceholder, text: $settings.aiModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
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
                .onChange(of: settings.aiFormat) { _, _ in testResult = nil }
            }
            MCPSection()
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("在搜索框里和 AI 聊天").font(.system(size: 14, weight: .semibold))
                Text("配置好网关后，搜索没有结果时按 ⇥ 或点「问 AI」，就在启动台里直接对话。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
        case nil:
            if !configured {
                Text("填好模型和密钥后可测试").font(.system(size: 12)).foregroundStyle(.secondary)
            }
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

/// How to add LaunchUS to Claude Code, Claude Desktop, Cursor and other MCP clients.
private struct MCPSection: View {
    private var executable: String {
        Bundle.main.executablePath ?? "/Applications/LaunchUS.app/Contents/MacOS/LaunchUS"
    }
    private var command: String { "claude mcp add launchus -- \"\(executable)\" --mcp" }
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
            Text("让 Claude、Cursor 等 AI 工具搜索和打开 App、退出 App、打开文件夹或分组、切换布局。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
            Card {
                snippet(title: "Claude Code", text: command)
                snippet(title: String(localized: "其他客户端（JSON 配置）"), text: json)
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
