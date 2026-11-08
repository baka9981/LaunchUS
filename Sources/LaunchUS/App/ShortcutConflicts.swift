import AppKit
import Carbon.HIToolbox

/// What else answers to a shortcut: a system shortcut (those never make registering fail, the
/// system just gets the key first), an everyday command in every app, another LaunchUS shortcut,
/// or another app that registered it first.
@MainActor
enum ShortcutConflicts {
    /// A warning for the shortcut, or nil when it's free.
    /// - owner: nil for the launcher's own shortcut, else the app or folder ID it opens.
    /// - others: every app and folder shortcut, by ID.
    /// - name: the name of an app or folder, for "same as …".
    static func message(_ spec: HotKeySpec, owner: String?, others: [String: HotKeySpec],
                        name: (String) -> String?) -> String? {
        let key = Combo(spec)
        if let title = systemShortcuts()[key] {
            return String(localized: "和系统的「\(title)」冲突，换一个或在系统设置 › 键盘里关掉它")
        }
        if let title = fixedSystem[key] {
            return String(localized: "和系统的「\(title)」冲突，换一个")
        }
        if let title = everyApp[key] {
            return String(localized: "会挡住所有 App 里的「\(title)」，建议换一个")
        }
        if owner != nil, let own = Settings.shared.hotKey, Combo(own) == key {
            return String(localized: "和打开 LaunchUS 的快捷键重复")
        }
        if let other = others.sorted(by: { $0.key < $1.key }).first(where: { $0.key != owner && Combo($0.value) == key }) {
            return String(localized: "和「\(name(other.key) ?? "?")」的快捷键重复")
        }
        if takenElsewhere(spec) {
            return String(localized: "已被其他 App 占用，换一个")
        }
        return nil
    }

    /// It's one of the system shortcuts that can be switched off in System Settings › Keyboard.
    static func isSystem(_ spec: HotKeySpec) -> Bool {
        systemShortcuts()[Combo(spec)] != nil
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Another app holds it: LaunchUS doesn't, and registering it fails.
    private static func takenElsewhere(_ spec: HotKeySpec) -> Bool {
        let key = Combo(spec)
        if let held = HotKeyCenter.heldSpec, Combo(held) == key { return false }
        if HotKeyGroup.all.contains(where: { $0.holds { Combo($0) == key } }) { return false }
        // Registering and dropping it again tells whether someone else has it.
        return HotKey(keyCode: spec.keyCode, modifiers: spec.modifiers, action: {}) == nil
    }

    // MARK: - Tables

    /// Key code plus Carbon modifiers; the display text doesn't matter.
    struct Combo: Hashable {
        let keyCode: Int
        let modifiers: Int

        init(_ spec: HotKeySpec) {
            keyCode = spec.keyCode
            modifiers = spec.modifiers & (cmdKey | optionKey | controlKey | shiftKey)
        }

        init(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            modifiers = HotKeyFormat.carbon(flags)
        }
    }

    /// The system's shortcuts that are switched on: the ones changed in System Settings, with
    /// macOS's defaults for the rest (those aren't written down until changed).
    static func systemShortcuts() -> [Combo: String] {
        let saved = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") as? [String: [String: Any]] ?? [:]
        var result: [Combo: String] = [:]
        for (id, entry) in defaults where saved[String(id)] == nil {
            result[entry.combo] = entry.title
        }
        for (id, item) in saved {
            guard (item["enabled"] as? Bool) == true || (item["enabled"] as? Int) == 1,
                  let value = item["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int], parameters.count >= 3,
                  parameters[1] != 65535 else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(parameters[2]))
            let combo = Combo(parameters[1], flags.intersection([.command, .option, .control, .shift]))
            result[combo] = Int(id).flatMap(title(of:)) ?? String(localized: "系统快捷键")
        }
        return result
    }

    private struct Entry {
        let combo: Combo
        let title: String
    }

    /// macOS's default system shortcuts, by their ID in com.apple.symbolichotkeys.
    private static var defaults: [Int: Entry] {
        let entries: [(Int, Int, NSEvent.ModifierFlags)] = [
            (28, kVK_ANSI_3, [.shift, .command]), (29, kVK_ANSI_3, [.control, .shift, .command]),
            (30, kVK_ANSI_4, [.shift, .command]), (31, kVK_ANSI_4, [.control, .shift, .command]),
            (184, kVK_ANSI_5, [.shift, .command]),
            (32, kVK_UpArrow, [.control]), (33, kVK_DownArrow, [.control]), (36, kVK_F11, []),
            (52, kVK_ANSI_D, [.option, .command]),
            (60, kVK_Space, [.control]), (61, kVK_Space, [.control, .option]),
            (64, kVK_Space, [.command]), (65, kVK_Space, [.option, .command]),
            (79, kVK_LeftArrow, [.control]), (81, kVK_RightArrow, [.control]),
            (98, kVK_ANSI_Slash, [.shift, .command]),
        ]
        var result: [Int: Entry] = [:]
        for (id, code, flags) in entries {
            if let title = title(of: id) { result[id] = Entry(combo: Combo(code, flags), title: title) }
        }
        return result
    }

    private static func title(of id: Int) -> String? {
        switch id {
        case 28: String(localized: "将屏幕图片存储为文件")
        case 29: String(localized: "将屏幕图片拷贝到剪贴板")
        case 30: String(localized: "将所选区域的图片存储为文件")
        case 31: String(localized: "将所选区域的图片拷贝到剪贴板")
        case 184: String(localized: "截屏和录制选项")
        case 32: String(localized: "调度中心")
        case 33: String(localized: "应用程序窗口")
        case 36: String(localized: "显示桌面")
        case 52: String(localized: "打开/关闭程序坞自动隐藏")
        case 60: String(localized: "选择上一个输入法")
        case 61: String(localized: "选择下一个输入法")
        case 64: String(localized: "显示聚焦搜索")
        case 65: String(localized: "显示访达搜索窗口")
        case 79, 80: String(localized: "向左移动一个空间")
        case 81, 82: String(localized: "向右移动一个空间")
        case 98: String(localized: "显示帮助菜单")
        case 118...133: String(localized: "切换到桌面 \(id - 117)")
        default: nil
        }
    }

    /// Built into macOS and not changeable.
    private static let fixedSystem: [Combo: String] = [
        Combo(kVK_Tab, [.command]): String(localized: "切换 App"),
        Combo(kVK_Tab, [.shift, .command]): String(localized: "切换 App"),
        Combo(kVK_Escape, [.option, .command]): String(localized: "强制退出"),
        Combo(kVK_ANSI_Q, [.control, .command]): String(localized: "锁定屏幕"),
        Combo(kVK_ANSI_Q, [.shift, .command]): String(localized: "退出登录"),
        Combo(kVK_Space, [.control, .command]): String(localized: "表情与符号"),
    ]

    /// Commands nearly every app has; a global shortcut would take them away everywhere.
    private static let everyApp: [Combo: String] = [
        Combo(kVK_ANSI_C, [.command]): String(localized: "拷贝"),
        Combo(kVK_ANSI_V, [.command]): String(localized: "粘贴"),
        Combo(kVK_ANSI_X, [.command]): String(localized: "剪切"),
        Combo(kVK_ANSI_Z, [.command]): String(localized: "撤销"),
        Combo(kVK_ANSI_Z, [.shift, .command]): String(localized: "重做"),
        Combo(kVK_ANSI_A, [.command]): String(localized: "全选"),
        Combo(kVK_ANSI_S, [.command]): String(localized: "存储"),
        Combo(kVK_ANSI_Q, [.command]): String(localized: "退出"),
        Combo(kVK_ANSI_W, [.command]): String(localized: "关闭窗口"),
        Combo(kVK_ANSI_N, [.command]): String(localized: "新建"),
        Combo(kVK_ANSI_T, [.command]): String(localized: "新建标签页"),
        Combo(kVK_ANSI_F, [.command]): String(localized: "查找"),
        Combo(kVK_ANSI_P, [.command]): String(localized: "打印"),
        Combo(kVK_ANSI_O, [.command]): String(localized: "打开"),
        Combo(kVK_ANSI_H, [.command]): String(localized: "隐藏"),
        Combo(kVK_ANSI_M, [.command]): String(localized: "最小化"),
        Combo(kVK_ANSI_Comma, [.command]): String(localized: "设置"),
    ]
}
