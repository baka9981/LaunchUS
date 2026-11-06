import SwiftUI
import AppKit
import Carbon.HIToolbox
import Observation

enum DisplayMode: String, CaseIterable { case fullScreen, window }
enum SortOrder: String, CaseIterable { case custom, name, recentlyAdded, recentlyUsed, mostUsed }
enum BrowseStyle: String, CaseIterable { case paged, scroll }
/// How fast the launcher's animations run.
enum AnimationSpeed: String, CaseIterable {
    case standard, fast, off

    var title: String {
        switch self {
        case .standard: String(localized: "标准")
        case .fast: String(localized: "快速")
        case .off: String(localized: "关闭动画")
        }
    }

    /// Scales a duration written for the standard speed.
    func duration(_ seconds: Double) -> Double {
        switch self {
        case .standard: seconds
        case .fast: seconds / 1.8
        case .off: 0
        }
    }

    /// Applied to every transaction in the launcher, so each `withAnimation` follows the setting.
    func adjust(_ transaction: inout Transaction) {
        switch self {
        case .standard: break
        case .fast: transaction.animation = transaction.animation?.speed(1.8)
        case .off:
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
enum BackgroundKind: String, CaseIterable { case wallpaper, glass, image }
/// Light or dark look for LaunchNew's cards, menus and window, apart from the Mac's own.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: String(localized: "自动")
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
/// When apps show the dark version of their icon, for those that have one.
enum DarkIconMode: String, CaseIterable {
    case auto, always, never

    var title: String {
        switch self {
        case .auto: String(localized: "跟随外观")
        case .always: String(localized: "始终")
        case .never: String(localized: "从不")
        }
    }

    func resolve(dark: Bool) -> Bool {
        switch self {
        case .auto: dark
        case .always: true
        case .never: false
        }
    }
}
enum HotCorner: String, CaseIterable { case off, topLeft, topRight, bottomLeft, bottomRight }
enum TargetScreen: String, CaseIterable { case dock, mouse, active, main }
enum ReturnHome: Int, CaseIterable {
    case immediately = 0, thirtySeconds = 30, oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900, oneHour = 3600, never = -1
}
/// What the Dock icon's menu lists.
enum DockMenuContent: String, CaseIterable { case pages, alphabetical, recent }
enum MultiSelectKey: String, CaseIterable { case off, command, shift }
enum AppIconStyle: Int, CaseIterable { case mono, blue, grid, rocket }

/// The menu bar icon: an SF Symbol, drawn as a template so it follows the menu bar's colour.
enum MenuBarIconStyle: String, CaseIterable {
    case grid = "square.grid.3x3.fill"
    case gridOutline = "square.grid.3x3"
    case grid2 = "square.grid.2x2.fill"
    case dots = "circle.grid.3x3.fill"
    case hexagons = "circle.hexagongrid.fill"
    case stack = "square.stack.3d.up.fill"

    var image: NSImage? {
        let image = NSImage(systemSymbolName: rawValue, accessibilityDescription: "LaunchNew")
        image?.isTemplate = true
        return image
    }
}

extension SortOrder {
    var title: String {
        switch self {
        case .custom: String(localized: "自定义")
        case .name: String(localized: "名称")
        case .recentlyAdded: String(localized: "添加日期")
        case .recentlyUsed: String(localized: "上次使用")
        case .mostUsed: String(localized: "使用频次")
        }
    }
}

extension DisplayMode {
    var title: String { self == .fullScreen ? String(localized: "全屏") : String(localized: "窗口") }
}

extension BrowseStyle {
    var title: String { self == .paged ? String(localized: "分页") : String(localized: "滚动") }
}

extension HotCorner {
    var title: String {
        switch self {
        case .off: String(localized: "关")
        case .topLeft: String(localized: "左上角")
        case .topRight: String(localized: "右上角")
        case .bottomLeft: String(localized: "左下角")
        case .bottomRight: String(localized: "右下角")
        }
    }
}

extension TargetScreen {
    var title: String {
        switch self {
        case .dock: String(localized: "程序坞所在屏幕")
        case .mouse: String(localized: "鼠标所在屏幕")
        case .active: String(localized: "当前窗口所在屏幕")
        case .main: String(localized: "主屏幕")
        }
    }
}

extension ReturnHome {
    var title: String {
        switch self {
        case .immediately: String(localized: "立即")
        case .thirtySeconds: String(localized: "30 秒后")
        case .oneMinute: String(localized: "1 分钟后")
        case .fiveMinutes: String(localized: "5 分钟后")
        case .fifteenMinutes: String(localized: "15 分钟后")
        case .oneHour: String(localized: "1 小时后")
        case .never: String(localized: "从不")
        }
    }
}

extension DockMenuContent {
    var title: String {
        switch self {
        case .pages: String(localized: "按页面和文件夹")
        case .alphabetical: String(localized: "全部 App（按字母）")
        case .recent: String(localized: "最近使用的 App")
        }
    }
}

extension MultiSelectKey {
    var title: String {
        switch self {
        case .off: String(localized: "关")
        case .command: String(localized: "按住 Cmd ⌘")
        case .shift: String(localized: "按住 Shift ⇧")
        }
    }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .off: nil
        case .command: .command
        case .shift: .shift
        }
    }
}

/// A global shortcut: Carbon key code and modifiers, plus how to show it.
struct HotKeySpec: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var display: String

    static let `default` = HotKeySpec(keyCode: kVK_Space, modifiers: optionKey, display: "⌥Space")
}

/// User preferences, stored in UserDefaults. Every change is announced with `Settings.didChange`.
@MainActor @Observable
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("LaunchNewSettingsDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    // 通用
    var hotKey: HotKeySpec { didSet { saveCodable(hotKey, "hotKey") } }
    var f4Key: Bool { didSet { save(f4Key, "f4Key") } }
    var trackpadPinch: Bool { didSet { save(trackpadPinch, "trackpadPinch") } }
    /// Fingers in the pinch, thumb included: 3, 4 or 5.
    var pinchFingers: Int { didSet { save(pinchFingers, "pinchFingers") } }
    var hotCorner: HotCorner { didSet { save(hotCorner.rawValue, "hotCorner") } }
    var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, "showMenuBarIcon") } }
    var menuBarIcon: MenuBarIconStyle { didSet { save(menuBarIcon.rawValue, "menuBarIcon") } }
    var showDockIcon: Bool { didSet { save(showDockIcon, "showDockIcon") } }
    var dockMenu: DockMenuContent { didSet { save(dockMenu.rawValue, "dockMenu") } }
    var appIcon: AppIconStyle { didSet { save(appIcon.rawValue, "appIcon") } }
    var multiSelectKey: MultiSelectKey { didSet { save(multiSelectKey.rawValue, "multiSelectKey") } }
    /// ✕ badges in jiggle mode.
    var deleteBadges: Bool { didSet { save(deleteBadges, "deleteBadges") } }

    // 界面
    var displayMode: DisplayMode { didSet { save(displayMode.rawValue, "displayMode") } }
    var hideDock: Bool { didSet { save(hideDock, "hideDock") } }
    var sortOrder: SortOrder { didSet { save(sortOrder.rawValue, "sortOrder") } }
    var browseStyle: BrowseStyle { didSet { save(browseStyle.rawValue, "browseStyle") } }
    /// How an open folder with more apps than fit is browsed.
    var folderBrowseStyle: BrowseStyle { didSet { save(folderBrowseStyle.rawValue, "folderBrowseStyle") } }
    var columns: Int { didSet { save(columns, "columns") } }
    var rows: Int { didSet { save(rows, "rows") } }
    /// Names under app icons.
    var hideNames: Bool { didSet { save(hideNames, "hideNames") } }
    var hideFolderNames: Bool { didSet { save(hideFolderNames, "hideFolderNames") } }
    /// Calendar's icon shows today's date.
    var dynamicCalendar: Bool { didSet { save(dynamicCalendar, "dynamicCalendar") } }
    /// Icon size relative to the default, 0.6…1.3.
    var iconScale: Double { didSet { save(iconScale, "iconScale") } }
    /// Fades apps not opened for three months.
    var fadeStale: Bool { didSet { save(fadeStale, "fadeStale") } }
    /// Folder tiles and the open folder use liquid glass instead of the smoked glass look.
    var liquidGlass: Bool { didSet { save(liquidGlass, "liquidGlass") } }
    var animationSpeed: AnimationSpeed { didSet { save(animationSpeed.rawValue, "animationSpeed") } }
    var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance") } }
    var darkIcons: DarkIconMode { didSet { save(darkIcons.rawValue, "darkIcons") } }
    /// The background gets darker still when the look is dark.
    var darkenBackground: Bool { didSet { save(darkenBackground, "darkenBackground") } }
    /// A blue dot before the names of newly installed apps, until they're first opened.
    var showNewDot: Bool { didSet { save(showNewDot, "showNewDot") } }
    /// A small dot under apps that are running.
    var showRunningDot: Bool { didSet { save(showRunningDot, "showRunningDot") } }
    /// Unread counts from the Dock, top-right on icons.
    var showBadges: Bool { didSet { save(showBadges, "showBadges") } }
    /// A row of recently opened apps under the search field.
    var showFrequent: Bool { didSet { save(showFrequent, "showFrequent") } }
    /// File name in `BackgroundImage.directory`, used when `background` is `.image`.
    var backgroundImage: String { didSet { save(backgroundImage, "backgroundImage") } }
    var background: BackgroundKind { didSet { save(background.rawValue, "background") } }
    /// Wallpaper blur radius in screen pixels.
    var blur: Double { didSet { save(blur, "blur") } }
    /// Black overlay on the background, 0…0.6.
    var dim: Double { didSet { save(dim, "dim") } }
    /// Frosted glass background's opacity, 0.2…1.
    var glassStrength: Double { didSet { save(glassStrength, "glassStrength") } }

    // Apps
    /// Extra folders scanned for apps, besides the default ones.
    var extraAppFolders: [String] { didSet { save(extraAppFolders, "extraAppFolders") } }

    // 隐藏的 App: secret ways in, all optional.
    /// A dot that only shows on hover, after the last page dot.
    var hiddenDotEntrance: Bool { didSet { save(hiddenDotEntrance, "hiddenDotEntrance") } }
    /// An empty slot after the last app of a page that shows a dashed outline on right-click.
    var hiddenSlotEntrance: Bool { didSet { save(hiddenSlotEntrance, "hiddenSlotEntrance") } }
    /// Page of that slot, 1-based; 0 is the last page.
    var hiddenSlotPage: Int { didSet { save(hiddenSlotPage, "hiddenSlotPage") } }
    /// Typing exactly this in the search field opens the hidden apps; empty turns it off.
    var hiddenPhrase: String { didSet { save(hiddenPhrase, "hiddenPhrase") } }
    /// Touch ID or the login password before hidden apps show.
    var hiddenRequireAuth: Bool { didSet { save(hiddenRequireAuth, "hiddenRequireAuth") } }
    /// Hide them again when the launcher closes.
    var hiddenRelock: Bool { didSet { save(hiddenRelock, "hiddenRelock") } }

    // 高级
    var targetScreen: TargetScreen { didSet { save(targetScreen.rawValue, "targetScreen") } }
    var returnHome: ReturnHome { didSet { save(returnHome.rawValue, "returnHome") } }
    var clickBackgroundToClose: Bool { didSet { save(clickBackgroundToClose, "clickBackgroundToClose") } }
    /// Automatic layout backups kept; 0 is off.
    var autoBackupCount: Int { didSet { save(autoBackupCount, "autoBackupCount") } }
    /// Keep the layout in step with other Macs through iCloud Drive.
    var iCloudSync: Bool { didSet { save(iCloudSync, "iCloudSync") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }
        hotKey = (d.data(forKey: "hotKey")).flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) } ?? .default
        f4Key = value("f4Key", false)
        trackpadPinch = value("trackpadPinch", false)
        let fingers = value("pinchFingers", 4)
        pinchFingers = fingers == TrackpadPinch.fourOrFive ? fingers : min(5, max(3, fingers))
        hotCorner = HotCorner(rawValue: value("hotCorner", "")) ?? .off
        showMenuBarIcon = value("showMenuBarIcon", true)
        menuBarIcon = MenuBarIconStyle(rawValue: value("menuBarIcon", "")) ?? .grid
        showDockIcon = value("showDockIcon", false)
        dockMenu = DockMenuContent(rawValue: value("dockMenu", "")) ?? .pages
        appIcon = AppIconStyle(rawValue: value("appIcon", 2)) ?? .grid
        multiSelectKey = MultiSelectKey(rawValue: value("multiSelectKey", "")) ?? .command
        deleteBadges = value("deleteBadges", true)

        displayMode = DisplayMode(rawValue: value("displayMode", "")) ?? .fullScreen
        hideDock = value("hideDock", true)
        sortOrder = SortOrder(rawValue: value("sortOrder", "")) ?? .custom
        browseStyle = BrowseStyle(rawValue: value("browseStyle", "")) ?? .paged
        folderBrowseStyle = BrowseStyle(rawValue: value("folderBrowseStyle", "")) ?? .paged
        columns = min(10, max(4, value("columns", 7)))
        rows = min(8, max(3, value("rows", 5)))
        hideNames = value("hideNames", false)
        hideFolderNames = value("hideFolderNames", value("hideNames", false))
        dynamicCalendar = value("dynamicCalendar", true)
        iconScale = min(1.3, max(0.6, value("iconScale", 1.0)))
        fadeStale = value("fadeStale", false)
        liquidGlass = value("liquidGlass", true)
        animationSpeed = AnimationSpeed(rawValue: value("animationSpeed", "")) ?? .standard
        appearance = AppearanceMode(rawValue: value("appearance", "")) ?? .system
        darkIcons = DarkIconMode(rawValue: value("darkIcons", "")) ?? .auto
        darkenBackground = value("darkenBackground", true)
        showNewDot = value("showNewDot", true)
        showRunningDot = value("showRunningDot", true)
        showBadges = value("showBadges", true)
        showFrequent = value("showFrequent", false)
        backgroundImage = value("backgroundImage", "")
        background = BackgroundKind(rawValue: value("background", "")) ?? .wallpaper
        blur = value("blur", 38.0)
        dim = value("dim", 0.2)
        glassStrength = min(1, max(0.2, value("glassStrength", 1.0)))

        extraAppFolders = value("extraAppFolders", [String]())
        hiddenDotEntrance = value("hiddenDotEntrance", true)
        hiddenSlotEntrance = value("hiddenSlotEntrance", false)
        hiddenSlotPage = max(0, value("hiddenSlotPage", 0))
        hiddenPhrase = value("hiddenPhrase", "")
        hiddenRequireAuth = value("hiddenRequireAuth", true)
        hiddenRelock = value("hiddenRelock", true)

        targetScreen = TargetScreen(rawValue: value("targetScreen", "")) ?? .dock
        returnHome = ReturnHome(rawValue: value("returnHome", 300)) ?? .fiveMinutes
        clickBackgroundToClose = value("clickBackgroundToClose", true)
        autoBackupCount = min(50, max(0, value("autoBackupCount", 10)))
        iCloudSync = value("iCloudSync", false)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: key)
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        save((try? JSONEncoder().encode(value)) ?? Data(), key)
    }

    /// Read off the main actor by the app scanner.
    nonisolated static var extraAppFolderPaths: [String] {
        UserDefaults.standard.stringArray(forKey: "extraAppFolders") ?? []
    }
}

/// The app's own language, set by overriding `AppleLanguages` for LaunchNew only.
/// Takes effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "", zhHans = "zh-Hans", zhHant = "zh-Hant", english = "en", japanese = "ja"
    var id: String { rawValue }

    /// Each language in its own script, so it can be found from any other.
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    static var current: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let first = (domain["AppleLanguages"] as? [String])?.first else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
