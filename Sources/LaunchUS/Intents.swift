import AppIntents
import AppKit

// Shortcuts actions. Each one runs the same command as the matching launchus:// link.

@MainActor
private func perform(_ command: URLCommand) {
    (NSApp.delegate as? AppDelegate)?.run(command)
}

struct OpenLauncherIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 LaunchUS"
    static let description = IntentDescription("显示启动台")

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchUS.perform(.open)
        return .result()
    }
}

struct OpenFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "打开文件夹"
    static let description = IntentDescription("显示启动台并打开指定名称的文件夹")

    @Parameter(title: "文件夹名称")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("打开文件夹 \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchUS.perform(.folder(name))
        return .result()
    }
}

struct SearchAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "搜索 App"
    static let description = IntentDescription("显示启动台并搜索")

    @Parameter(title: "搜索内容")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("在 LaunchUS 中搜索 \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchUS.perform(.search(text))
        return .result()
    }
}

struct SwitchLayoutIntent: AppIntent {
    static let title: LocalizedStringResource = "切换布局方案"
    static let description = IntentDescription("切换到指定名称的布局方案；「默认」是最初的布局")

    @Parameter(title: "布局名称")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("切换到布局 \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchUS.perform(.profile(name))
        return .result()
    }
}

struct LaunchUSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenLauncherIntent(), phrases: ["打开 \(.applicationName)", "Open \(.applicationName)"],
                    shortTitle: "打开 LaunchUS", systemImageName: "square.grid.3x3.fill")
        AppShortcut(intent: SearchAppsIntent(), phrases: ["在 \(.applicationName) 中搜索", "Search in \(.applicationName)"],
                    shortTitle: "搜索 App", systemImageName: "magnifyingglass")
    }
}
