import SwiftUI

/// A widget on the home grid: which widget it is and how many cells it takes.
struct WidgetItem: Codable, Hashable, Identifiable {
    enum Size: String, Codable, CaseIterable {
        case small, medium, large

        var title: String {
            switch self {
            case .small: String(localized: "小")
            case .medium: String(localized: "中")
            case .large: String(localized: "大")
            }
        }

        /// Cells across and down before the grid limits it.
        var cells: (width: Int, height: Int) {
            switch self {
            case .small: (2, 2)
            case .medium: (4, 2)
            case .large: (4, 4)
            }
        }

        /// 2 × 2, 4 × 2 and 4 × 4 cells, never more than the grid has.
        func span(columns: Int, rows: Int) -> (width: Int, height: Int) {
            let (w, h) = cells
            return (max(1, min(w, columns)), max(1, min(h, rows)))
        }
    }

    var id: String
    /// The provider's ID: `launchus.clock` and the other built-in ones, or a plugin's
    /// reverse-DNS ID (see docs/WIDGETS.md).
    var kind: String
    var size: Size

    init(id: String = UUID().uuidString, kind: String, size: Size) {
        self.id = id
        self.kind = kind
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let kind = try c.decode(String.self, forKey: .kind)
        // Early builds stored the built-in kinds without the prefix.
        self.kind = ["clock", "system", "calendar"].contains(kind) ? "launchus." + kind : kind
        // A size from a newer version reads as the smallest.
        size = (try? c.decode(Size.self, forKey: .size)) ?? .small
    }
}

/// The built-in widgets, in the order the gallery lists them.
enum BuiltInWidget: String, CaseIterable {
    case clock = "launchus.clock"
    case analogClock = "launchus.analog-clock"
    case calendar = "launchus.calendar"
    case countdown = "launchus.countdown"
    case progress = "launchus.progress"
    case system = "launchus.system"
    case battery = "launchus.battery"
    case network = "launchus.network"
    case storage = "launchus.storage"
    case note = "launchus.note"
    case todo = "launchus.todo"
    case apps = "launchus.apps"
    case timer = "launchus.timer"
    case actions = "launchus.actions"
    case clipboard = "launchus.clipboard"

    /// How the gallery groups widgets.
    enum Category: CaseIterable {
        case time, tools, system, plugin

        var title: String {
            switch self {
            case .time: String(localized: "时间与日程")
            case .tools: String(localized: "实用工具")
            case .system: String(localized: "系统")
            case .plugin: String(localized: "插件")
            }
        }
    }

    var category: Category {
        switch self {
        case .clock, .analogClock, .calendar, .countdown, .progress: .time
        case .note, .todo, .apps, .timer, .actions, .clipboard: .tools
        case .system, .battery, .network, .storage: .system
        }
    }

    var name: String {
        switch self {
        case .clock: String(localized: "时钟与日期")
        case .analogClock: String(localized: "指针时钟")
        case .calendar: String(localized: "日历与提醒事项")
        case .countdown: String(localized: "节日倒数")
        case .progress: String(localized: "时间进度")
        case .system: String(localized: "系统状态")
        case .battery: String(localized: "电池")
        case .network: String(localized: "网络")
        case .storage: String(localized: "存储空间")
        case .note: String(localized: "便签")
        case .apps: String(localized: "常用应用")
        case .timer: String(localized: "计时器")
        case .actions: String(localized: "快捷操作")
        case .todo: String(localized: "待办")
        case .clipboard: String(localized: "剪贴板")
        }
    }

    var summary: String {
        switch self {
        case .clock: String(localized: "时间、日期、农历和世界时钟，大尺寸还有月历。")
        case .analogClock: String(localized: "表盘时钟。中、大尺寸同时显示本地和三个城市的时间，白天浅色、夜晚深色。")
        case .calendar: String(localized: "今天的日程和未完成的提醒事项。需要日历和提醒事项的访问权限。")
        case .countdown: String(localized: "离下一个节日还有几天。中文环境显示春节、中秋等传统节日。")
        case .progress: String(localized: "今天、本周、本月和今年已经过去多少，大尺寸还有全年的日历点阵。")
        case .system: String(localized: "CPU、内存、磁盘、电池和网速，每两秒更新。")
        case .battery: String(localized: "Mac 的电量和剩余时间，以及蓝牙键盘、鼠标和触控板的电量。")
        case .network: String(localized: "实时上传和下载速度，最近两分钟的曲线和本机地址。")
        case .storage: String(localized: "启动磁盘和外接磁盘的已用和可用空间。")
        case .note: String(localized: "随手记点东西，支持 Markdown。点一下直接在卡片上写，右键换纸的颜色。")
        case .apps: String(localized: "固定在最近一行的 App 和最近打开的 App，点图标直接打开。")
        case .timer: String(localized: "番茄钟和倒计时。点一下开始或暂停，右键选时长，时间到了会提醒。")
        case .actions: String(localized: "锁屏、截屏、深色模式、静音、睡眠、保持唤醒和清空废纸篓，一点就做。")
        case .todo: String(localized: "待办清单。点一项打勾，点 + 直接在卡片上添加，右键清除已完成。")
        case .clipboard: String(localized: "最近拷贝的文字，点一条重新拷贝。只存在内存里，退出就清空，密码管理器拷贝的不记录。")
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .analogClock: "clock.circle"
        case .calendar: "calendar"
        case .countdown: "gift"
        case .progress: "chart.bar.xaxis"
        case .system: "gauge.with.dots.needle.33percent"
        case .battery: "battery.75percent"
        case .network: "network"
        case .storage: "internaldrive"
        case .note: "note.text"
        case .apps: "square.grid.3x3.fill"
        case .timer: "timer"
        case .actions: "bolt.fill"
        case .todo: "checklist"
        case .clipboard: "doc.on.clipboard"
        }
    }

    /// The tile colour in the gallery.
    var tint: (top: Color, bottom: Color) {
        switch self {
        case .clock, .analogClock: (Color(red: 0.36, green: 0.36, blue: 0.4), Color(red: 0.12, green: 0.12, blue: 0.14))
        case .calendar: (Color(red: 1, green: 0.38, blue: 0.35), Color(red: 0.86, green: 0.15, blue: 0.2))
        case .countdown: (Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.95, green: 0.35, blue: 0.2))
        case .progress: (Color(red: 0.45, green: 0.85, blue: 0.5), Color(red: 0.15, green: 0.62, blue: 0.35))
        case .system: (Color(red: 0.4, green: 0.65, blue: 1), Color(red: 0.15, green: 0.4, blue: 0.9))
        case .battery: (Color(red: 0.4, green: 0.9, blue: 0.55), Color(red: 0.1, green: 0.66, blue: 0.4))
        case .network: (Color(red: 0.35, green: 0.8, blue: 1), Color(red: 0.1, green: 0.5, blue: 0.85))
        case .storage: (Color(red: 0.7, green: 0.72, blue: 0.78), Color(red: 0.42, green: 0.45, blue: 0.52))
        case .note: (Color(red: 1, green: 0.88, blue: 0.4), Color(red: 0.96, green: 0.7, blue: 0.15))
        case .apps: (Color(red: 0.55, green: 0.5, blue: 1), Color(red: 0.32, green: 0.25, blue: 0.85))
        case .timer: (Color(red: 1, green: 0.45, blue: 0.4), Color(red: 0.88, green: 0.2, blue: 0.25))
        case .actions: (Color(red: 0.35, green: 0.85, blue: 0.85), Color(red: 0.1, green: 0.55, blue: 0.65))
        case .todo: (Color(red: 0.4, green: 0.75, blue: 1), Color(red: 0.15, green: 0.45, blue: 0.95))
        case .clipboard: (Color(red: 0.75, green: 0.6, blue: 0.45), Color(red: 0.5, green: 0.36, blue: 0.25))
        }
    }

    /// What a click opens, and the menu item for it.
    var openTarget: (title: String, url: URL)? {
        let app: (String, String)? = switch self {
        case .clock, .analogClock: (String(localized: "打开时钟"), "/System/Applications/Clock.app")
        case .calendar, .countdown, .progress: (String(localized: "打开日历"), "/System/Applications/Calendar.app")
        case .system, .network: (String(localized: "打开活动监视器"), "/System/Applications/Utilities/Activity Monitor.app")
        case .storage: (String(localized: "打开磁盘工具"), "/System/Applications/Utilities/Disk Utility.app")
        case .battery, .note, .todo, .apps, .timer, .actions, .clipboard: nil
        }
        if let (title, path) = app {
            return FileManager.default.fileExists(atPath: path) ? (title, URL(fileURLWithPath: path)) : nil
        }
        guard self == .battery else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension").map { (String(localized: "打开电池设置"), $0) }
    }
}
