import SwiftUI
import AppKit
import Carbon.HIToolbox
import Observation

enum DisplayMode: String, CaseIterable, Codable { case fullScreen, window, ring }
enum SortOrder: String, CaseIterable, Codable { case custom, name, recentlyAdded, recentlyUsed, mostUsed }
enum BrowseStyle: String, CaseIterable, Codable { case paged, scroll }
/// How fast the launcher's animations run.
/// Where "search the web" goes when search finds nothing.
enum SearchEngine: String, CaseIterable, Codable {
    case google, bing, baidu, duckDuckGo

    var title: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .baidu: String(localized: "百度")
        case .duckDuckGo: "DuckDuckGo"
        }
    }

    func url(for text: String) -> URL? {
        var parts: URLComponents
        switch self {
        case .google: parts = URLComponents(string: "https://www.google.com/search")!; parts.queryItems = [URLQueryItem(name: "q", value: text)]
        case .bing: parts = URLComponents(string: "https://www.bing.com/search")!; parts.queryItems = [URLQueryItem(name: "q", value: text)]
        case .baidu: parts = URLComponents(string: "https://www.baidu.com/s")!; parts.queryItems = [URLQueryItem(name: "wd", value: text)]
        case .duckDuckGo: parts = URLComponents(string: "https://duckduckgo.com/")!; parts.queryItems = [URLQueryItem(name: "q", value: text)]
        }
        // A "+" left as is reads as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }
}

/// How fast the launcher animates: a rate relative to the standard speed, or not at all.
struct AnimationSpeed: Equatable {
    /// 1 is the standard speed, 2 twice as fast.
    var rate = 1.0
    var off = false

    static let standard = AnimationSpeed()
    static let rateRange: ClosedRange<Double> = 0.5...2.5
    /// The standard speed (1×) runs this much faster than the durations written in the code.
    static let base = 1.2

    /// How much faster than written the animations run.
    var speed: Double { rate * Self.base }

    /// Scales a duration written in the code to the chosen speed.
    func duration(_ seconds: Double) -> Double {
        off ? 0 : seconds / speed
    }

    /// Applied to every transaction in the launcher, so each `withAnimation` follows the setting.
    func adjust(_ transaction: inout Transaction) {
        if off {
            transaction.animation = nil
            transaction.disablesAnimations = true
        } else {
            transaction.animation = transaction.animation?.speed(speed)
        }
    }
}

/// A cubic Bézier timing curve for the launcher's transitions, like CSS's `cubic-bezier()`:
/// time runs along x from 0 to 1, progress up y. y may leave 0…1 to undershoot or overshoot.
struct MotionCurve: Codable, Equatable, Hashable {
    var x1: Double, y1: Double, x2: Double, y2: Double

    static let yRange: ClosedRange<Double> = -0.6...1.6

    /// Keeps time moving forward (x in 0…1) and the bounce within reason.
    var clamped: MotionCurve {
        MotionCurve(x1: min(1, max(0, x1)), y1: min(Self.yRange.upperBound, max(Self.yRange.lowerBound, y1)),
                    x2: min(1, max(0, x2)), y2: min(Self.yRange.upperBound, max(Self.yRange.lowerBound, y2)))
    }

    func animation(duration: Double) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }

    /// Progress at time `t`, for drawing and previewing the curve.
    func point(_ t: Double) -> CGPoint {
        let u = 1 - t
        let x = 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t
        let y = 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t
        return CGPoint(x: x, y: y)
    }

    /// Progress at clock time `x`: solves the curve's x for its t first.
    func value(at x: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if point(mid).x < x { lo = mid } else { hi = mid }
        }
        return point((lo + hi) / 2).y
    }

    struct Preset: Identifiable {
        let title: String
        let curve: MotionCurve
        var id: String { title }
    }

    static var presets: [Preset] {
        [
            Preset(title: String(localized: "缓出"), curve: MotionCurve(x1: 0.16, y1: 1, x2: 0.3, y2: 1)),
            Preset(title: String(localized: "缓入缓出"), curve: MotionCurve(x1: 0.65, y1: 0, x2: 0.35, y2: 1)),
            Preset(title: String(localized: "线性"), curve: MotionCurve(x1: 0, y1: 0, x2: 1, y2: 1)),
            Preset(title: String(localized: "回弹"), curve: MotionCurve(x1: 0.34, y1: 1.45, x2: 0.64, y2: 1)),
            Preset(title: String(localized: "先收后放"), curve: MotionCurve(x1: 0.6, y1: -0.35, x2: 0.4, y2: 1.35)),
        ]
    }
}

enum BackgroundKind: String, CaseIterable, Codable { case wallpaper, glass, image, dynamic }
/// What a 动态 background shows.
enum DynamicWallpaper: String, CaseIterable, Codable {
    /// The sky's colour through the day: dawn, day, dusk, night.
    case sky
    /// A city's weather live: rain, snow, clouds, fog, thunder, over its sky.
    case weather
    /// A video of the user's own, looping silently.
    case live

    var title: String {
        switch self {
        case .sky: String(localized: "天色")
        case .weather: String(localized: "城市天气")
        case .live: String(localized: "视频")
        }
    }
}
/// Light or dark look for LaunchUS's cards, menus and window, apart from the Mac's own.
enum AppearanceMode: String, CaseIterable, Codable {
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
enum DarkIconMode: String, CaseIterable, Codable {
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
enum HotCorner: String, CaseIterable, Codable { case off, topLeft, topRight, bottomLeft, bottomRight }
/// The mouse button clicked quickly to open a profile: `NSEvent.buttonNumber`, picked by
/// pressing it, so only buttons the mouse really has can be chosen.
enum MouseButton {
    static let off = -1
    static func title(_ number: Int) -> String {
        switch number {
        case ..<0: String(localized: "未设置")
        case 0: String(localized: "左键")
        case 1: String(localized: "右键")
        case 2: String(localized: "中键")
        default: String(format: String(localized: "侧键 %lld"), number - 2)
        }
    }
}
enum TargetScreen: String, CaseIterable, Codable { case dock, mouse, active, main }
enum ReturnHome: Int, CaseIterable, Codable {
    case immediately = 0, thirtySeconds = 30, oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900, oneHour = 3600, never = -1
}
/// How readily the mouse wheel turns pages: 0 slowest, 0.5 one page a spin, 1 fastest.
extension Settings {
    /// LaunchUS's own, not a profile's: 每日反馈提醒 on the 激活 page.
    static let feedbackReminderKey = "dailyFeedbackReminder"
}

enum WheelSpeed {
    /// Wheel notches per page: 6 at the slow end, 1 at the fast end, evenly in between as felt
    /// (each step of the slider multiplies by the same amount).
    static func notches(_ s: Double) -> Double { pow(6, 1 - min(1, max(0, s))) }
    /// Least gap between two flips, so a quick spin can't run through pages faster than they
    /// slide: a third of a second slow, a tenth fast.
    static func interval(_ s: Double) -> TimeInterval { 0.35 - 0.25 * min(1, max(0, s)) }
    /// A pause this long starts the count over, so a leftover part of a page doesn't add to the
    /// next spin.
    static let pause: TimeInterval = 0.5
    /// "约滚 3 格翻一页" for the setting.
    static func notchesText(_ s: Double) -> String {
        let n = Int(notches(s).rounded())
        return n <= 1 ? String(localized: "滚一格翻一页") : String(format: String(localized: "滚约 %lld 格翻一页"), n)
    }
}
/// What the Dock icon's menu lists.
enum DockMenuContent: String, CaseIterable, Codable { case pages, alphabetical, recent }
enum MultiSelectKey: String, CaseIterable, Codable { case off, command, shift }
/// Raw values are what's saved; the order here is the picker's.
enum AppIconStyle: Int, CaseIterable, Codable { case mono = 0, blue = 1, grid = 2, dots = 4, rocket = 3 }

/// The menu bar icon: an SF Symbol, drawn as a template so it follows the menu bar's colour.
enum MenuBarIconStyle: String, CaseIterable, Codable {
    case grid = "square.grid.3x3.fill"
    case gridOutline = "square.grid.3x3"
    case grid2 = "square.grid.2x2.fill"
    case dots = "circle.grid.3x3.fill"
    case hexagons = "circle.hexagongrid.fill"
    case stack = "square.stack.3d.up.fill"

    var image: NSImage? {
        let image = NSImage(systemSymbolName: rawValue, accessibilityDescription: "LaunchUS")
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
    var title: String {
        switch self {
        case .fullScreen: String(localized: "全屏")
        case .window: String(localized: "窗口")
        case .ring: String(localized: "圆环")
        }
    }
    var symbol: String {
        switch self {
        case .fullScreen: "rectangle.inset.filled"
        case .window: "macwindow"
        case .ring: "circle.circle"
        }
    }
    var summary: String {
        switch self {
        case .fullScreen: String(localized: "铺满屏幕，像原来的启动台")
        case .window: String(localized: "浮在桌面上，像一个 App 窗口")
        case .ring: String(localized: "围着指针排成一圈，点一下就开")
        }
    }
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
struct HotKeySpec: Codable, Hashable {
    var keyCode: Int
    var modifiers: Int
    var display: String

    static let `default` = HotKeySpec(keyCode: kVK_Space, modifiers: optionKey, display: "⌥Space")
}

/// User preferences, stored in UserDefaults. Every change is announced with `Settings.didChange`.
@MainActor @Observable
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("LaunchUSSettingsDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    // 通用
    /// nil: this profile has no shortcut of its own.
    var hotKey: HotKeySpec? { didSet { saveCodable(hotKey, "hotKey") } }
    var f4Key: Bool { didSet { save(f4Key, "f4Key") } }
    var trackpadPinch: Bool { didSet { save(trackpadPinch, "trackpadPinch") } }
    /// Fingers in the pinch, thumb included: 3, 4 or 5.
    var pinchFingers: Int { didSet { save(pinchFingers, "pinchFingers") } }
    var hotCorner: HotCorner { didSet { save(hotCorner.rawValue, "hotCorner") } }
    /// The mouse button clicked quickly `clickCount` times to open this profile.
    var clickButton: Int { didSet { save(clickButton, "clickButton") } }
    var clickCount: Int { didSet { save(clickCount, "clickCount") } }
    /// Whether this profile starts with the Mac; LaunchUS is a login item while any profile does.
    var startAtLogin: Bool { didSet { save(startAtLogin, "startAtLogin") } }
    /// This profile's language, put into `AppleLanguages` (read at launch, so a change needs a relaunch).
    var language: AppLanguage {
        didSet {
            if defaults === UserDefaults.standard { language.apply() }
            save(language.rawValue, "language")
        }
    }
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
    /// How the home pages actually behave: the ring always turns pages, whatever the grid's style.
    var pageStyle: BrowseStyle { displayMode == .ring ? .paged : browseStyle }
    /// How an open folder with more apps than fit is browsed.
    var folderBrowseStyle: BrowseStyle { didSet { save(folderBrowseStyle.rawValue, "folderBrowseStyle") } }
    /// Window mode's row of category tabs under the search field.
    var showCategoryBar: Bool { didSet { save(showCategoryBar, "showCategoryBar") } }
    /// The daily anonymous ping (Heartbeat): on unless the user turns it off. Without it no ping
    /// goes out, so the two below only add to it.
    var shareUsage: Bool { didSet { save(shareUsage, "shareUsage") } }
    /// The ping also says which features are on (full screen, smart bar, iCloud, AI).
    var shareFeatures: Bool { didSet { save(shareFeatures, "shareFeatures") } }
    /// The ping also says how often the launcher opened, and by what.
    var shareOpens: Bool { didSet { save(shareOpens, "shareOpens") } }
    /// Crash reports, sent on their own (see `CrashReports`).
    var shareCrashes: Bool { didSet { save(shareCrashes, "shareCrashes") } }
    /// Tab keys in the order the user put them; tabs not in it keep their default place after these.
    var categoryTabOrder: [String] { didSet { save(categoryTabOrder, "categoryTabOrder") } }
    var hiddenCategoryTabs: [String] { didSet { save(hiddenCategoryTabs, "hiddenCategoryTabs") } }
    var columns: Int { didSet { save(columns, "columns") } }
    /// Icons stay in whichever cell they're dropped in, leaving empty cells, instead of lining up one after another.
    var freePlacement: Bool { didSet { save(freePlacement, "freePlacement") } }
    var rows: Int { didSet { save(rows, "rows") } }
    /// Names under app icons.
    var hideNames: Bool { didSet { save(hideNames, "hideNames") } }
    var hideFolderNames: Bool { didSet { save(hideFolderNames, "hideFolderNames") } }
    /// Calendar's icon shows today's date.
    var dynamicCalendar: Bool { didSet { save(dynamicCalendar, "dynamicCalendar") } }
    /// Icon size relative to the default, 0.6…1.3.
    /// Icon size in full screen (saved under the key it had before window mode got its own).
    var fullIconScale: Double { didSet { save(fullIconScale, "iconScale") } }
    var windowIconScale: Double { didSet { save(windowIconScale, "windowIconScale") } }
    /// The window's size against the standard one, in window mode.
    var windowSize: Double { didSet { save(windowSize, "windowSize") } }
    static let windowSizeRange: ClosedRange<Double> = 0.8...1.3

    /// Each display mode keeps its own icon size; this is the one in use.
    var iconScale: Double {
        get { iconScale(for: displayMode) }
        set { setIconScale(newValue, for: displayMode) }
    }

    func iconScale(for mode: DisplayMode) -> Double { mode == .window ? windowIconScale : fullIconScale }

    func setIconScale(_ value: Double, for mode: DisplayMode) {
        if mode == .window { windowIconScale = value } else { fullIconScale = value }
    }
    /// Fades apps not opened for three months.
    var fadeStale: Bool { didSet { save(fadeStale, "fadeStale") } }
    /// Folder tiles and the open folder use liquid glass instead of the smoked glass look.
    var liquidGlass: Bool { didSet { save(liquidGlass, "liquidGlass") } }
    /// Animation speed relative to the standard, 0.5…2.5.
    var animationRate: Double { didSet { save(animationRate, "animationRate") } }
    var animationsOff: Bool { didSet { save(animationsOff, "animationsOff") } }
    var animationSpeed: AnimationSpeed { AnimationSpeed(rate: animationRate, off: animationsOff) }
    /// Timing curve for opening, closing, page turns and folders; `nil` keeps the built-in springs.
    var motionCurve: MotionCurve? {
        didSet {
            if let motionCurve { saveCodable(motionCurve, "motionCurve") } else { save(Data(), "motionCurve") }
        }
    }
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
    /// Icons lift a little under the pointer, like they do while their right-click menu is open.
    var hoverLift: Bool { didSet { save(hoverLift, "hoverLift") } }
    /// File name in `BackgroundImage.directory`, used when `background` is `.image`.
    var backgroundImage: String { didSet { save(backgroundImage, "backgroundImage") } }
    var background: BackgroundKind { didSet { save(background.rawValue, "background") } }
    var dynamicWallpaper: DynamicWallpaper { didSet { save(dynamicWallpaper.rawValue, "dynamicWallpaper") } }
    /// The city for 城市天气, as found by the weather service; empty uses the Mac's time zone.
    var weatherCity: String { didSet { save(weatherCity, "weatherCity") } }
    var weatherLatitude: Double { didSet { save(weatherLatitude, "weatherLatitude") } }
    var weatherLongitude: Double { didSet { save(weatherLongitude, "weatherLongitude") } }
    /// The city, temperature and weather in a corner of a 城市天气 background.
    var showWeatherLabel: Bool { didSet { save(showWeatherLabel, "showWeatherLabel") } }
    /// File name in `LiveWallpaper.directory`, for 动态 › 视频.
    var liveWallpaper: String { didSet { save(liveWallpaper, "liveWallpaper") } }
    /// Wallpaper blur radius in screen points, 0…240.
    var blur: Double { didSet { save(blur, "blur") } }
    /// Colour of the wallpaper or picture: 1 as is, 0 grey, up to 2 more vivid.
    var backgroundSaturation: Double { didSet { save(backgroundSaturation, "backgroundSaturation") } }
    /// Black overlay on the background, 0…0.6.
    var dim: Double { didSet { save(dim, "dim") } }
    /// Frosted glass background's opacity, 0.2…1.
    var glassStrength: Double { didSet { save(glassStrength, "glassStrength") } }
    /// Warm (1) or cool (-1) cast over the background, 0 leaves it neutral.
    var backgroundTemperature: Double { didSet { save(backgroundTemperature, "backgroundTemperature") } }
    /// Hue of the colour wash, 0…1 around the colour wheel.
    var backgroundTintHue: Double { didSet { save(backgroundTintHue, "backgroundTintHue") } }
    /// How strongly the background takes on `backgroundTintHue`, 0…1.
    var backgroundTint: Double { didSet { save(backgroundTint, "backgroundTint") } }
    /// Film grain over the background, 0…1.
    var backgroundGrain: Double { didSet { save(backgroundGrain, "backgroundGrain") } }
    /// Darkened corners, 0…1.
    var backgroundVignette: Double { didSet { save(backgroundVignette, "backgroundVignette") } }
    /// Looks the user saved, shown after the built-in ones.
    var savedBackgroundStyles: [BackgroundStyle.Saved] { didSet { saveCodable(savedBackgroundStyles, "savedBackgroundStyles") } }

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
    var wheelSpeed: Double { didSet { save(wheelSpeed, "wheelSpeed") } }
    var searchEngine: SearchEngine { didSet { save(searchEngine.rawValue, "searchEngine") } }
    /// Show matching files and folders from Spotlight under the app results.
    var searchFiles: Bool { didSet { save(searchFiles, "searchFiles") } }
    /// Automatic layout backups kept; 0 is off.
    var autoBackupCount: Int { didSet { save(autoBackupCount, "autoBackupCount") } }
    /// Keep the layout in step with other Macs through iCloud Drive.
    var iCloudSync: Bool { didSet { save(iCloudSync, "iCloudSync") } }

    // AI
    /// Which API the gateway speaks.
    var aiFormat: AIFormat { didSet { save(aiFormat.rawValue, "aiFormat") } }
    /// The gateway's base URL; empty uses the format's own.
    var aiBaseURL: String { didSet { save(aiBaseURL, "aiBaseURL") } }
    var aiModel: String { didSet { save(aiModel, "aiModel") } }
    /// Optional instructions sent before every chat.
    var aiSystemPrompt: String { didSet { save(aiSystemPrompt, "aiSystemPrompt") } }
    /// Whether the chat may look up and act on apps, folders and layouts.
    var aiToolAccess: AIToolAccess { didSet { save(aiToolAccess.rawValue, "aiToolAccess") } }
    /// Past chats kept on this Mac; 0 keeps none and removes what's there.
    var aiHistoryCount: Int {
        didSet {
            save(aiHistoryCount, "aiHistoryCount")
            // Only the app's own settings: a scratch copy (tests, checking a waiting profile's
            // value) mustn't delete chats.
            if aiHistoryCount < oldValue, defaults === UserDefaults.app { ChatHistory.prune(keeping: aiHistoryCount) }
        }
    }

    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
        let d = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }
        freePlacement = value("freePlacement", false)
        // Saved as JSON; "null" means the shortcut was cleared.
        hotKey = .default
        if let data = d.data(forKey: "hotKey") {
            do { hotKey = try JSONDecoder().decode(Optional<HotKeySpec>.self, from: data) } catch {}
        }
        f4Key = value("f4Key", false)
        trackpadPinch = value("trackpadPinch", false)
        let fingers = value("pinchFingers", 4)
        pinchFingers = fingers == TrackpadPinch.fourOrFive ? fingers : min(5, max(3, fingers))
        hotCorner = HotCorner(rawValue: value("hotCorner", "")) ?? .off
        clickButton = max(-1, value("clickButton", MouseButton.off))
        clickCount = min(5, max(2, value("clickCount", 3)))
        startAtLogin = value("startAtLogin", false)
        language = AppLanguage(rawValue: value("language", d === UserDefaults.standard ? AppLanguage.current.rawValue : "")) ?? .system
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
        showCategoryBar = value("showCategoryBar", true)
        shareUsage = value("shareUsage", true)
        shareFeatures = value("shareFeatures", true)
        shareOpens = value("shareOpens", true)
        shareCrashes = value("shareCrashes", true)
        categoryTabOrder = value("categoryTabOrder", [String]())
        hiddenCategoryTabs = value("hiddenCategoryTabs", [String]())
        columns = min(10, max(4, value("columns", 7)))
        rows = min(8, max(3, value("rows", 5)))
        hideNames = value("hideNames", false)
        hideFolderNames = value("hideFolderNames", value("hideNames", false))
        dynamicCalendar = value("dynamicCalendar", true)
        let fullScale = min(1.3, max(0.6, value("iconScale", 1.0)))
        fullIconScale = fullScale
        // Window mode starts from the size people already chose.
        windowIconScale = min(1.3, max(0.6, value("windowIconScale", fullScale)))
        windowSize = min(Self.windowSizeRange.upperBound, max(Self.windowSizeRange.lowerBound, value("windowSize", 1.0)))
        fadeStale = value("fadeStale", false)
        liquidGlass = value("liquidGlass", true)
        // Earlier versions had three fixed choices: standard, fast (1.8× the old standard,
        // which is 1.5× today's) and off.
        let oldSpeed = value("animationSpeed", "")
        animationRate = min(AnimationSpeed.rateRange.upperBound, max(AnimationSpeed.rateRange.lowerBound,
                            value("animationRate", oldSpeed == "fast" ? 1.5 : 1.0)))
        animationsOff = value("animationsOff", oldSpeed == "off")
        motionCurve = d.data(forKey: "motionCurve").flatMap { try? JSONDecoder().decode(MotionCurve.self, from: $0) }?.clamped
        appearance = AppearanceMode(rawValue: value("appearance", "")) ?? .system
        darkIcons = DarkIconMode(rawValue: value("darkIcons", "")) ?? .auto
        darkenBackground = value("darkenBackground", true)
        showNewDot = value("showNewDot", true)
        showRunningDot = value("showRunningDot", true)
        showBadges = value("showBadges", true)
        showFrequent = value("showFrequent", false)
        hoverLift = value("hoverLift", false)
        backgroundImage = value("backgroundImage", "")
        background = BackgroundKind(rawValue: value("background", "")) ?? .wallpaper
        dynamicWallpaper = DynamicWallpaper(rawValue: value("dynamicWallpaper", "")) ?? .sky
        weatherCity = value("weatherCity", "")
        weatherLatitude = value("weatherLatitude", 0.0)
        weatherLongitude = value("weatherLongitude", 0.0)
        showWeatherLabel = value("showWeatherLabel", true)
        liveWallpaper = value("liveWallpaper", "")
        blur = value("blur", 38.0)
        backgroundSaturation = min(2, max(0, value("backgroundSaturation", 1.05)))
        dim = value("dim", 0.2)
        glassStrength = min(1, max(0.2, value("glassStrength", 1.0)))
        backgroundTemperature = min(1, max(-1, value("backgroundTemperature", 0.0)))
        backgroundTintHue = min(1, max(0, value("backgroundTintHue", 0.6)))
        backgroundTint = min(1, max(0, value("backgroundTint", 0.0)))
        backgroundGrain = min(1, max(0, value("backgroundGrain", 0.0)))
        backgroundVignette = min(1, max(0, value("backgroundVignette", 0.0)))
        savedBackgroundStyles = d.data(forKey: "savedBackgroundStyles")
            .flatMap { try? JSONDecoder().decode([BackgroundStyle.Saved].self, from: $0) } ?? []

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
        wheelSpeed = min(1, max(0, value("wheelSpeed", 0.5)))
        searchEngine = SearchEngine(rawValue: value("searchEngine", "")) ?? .google
        searchFiles = value("searchFiles", true)
        autoBackupCount = min(50, max(0, value("autoBackupCount", 10)))
        iCloudSync = value("iCloudSync", false)

        aiFormat = AIFormat(rawValue: value("aiFormat", "")) ?? .openAI
        aiBaseURL = value("aiBaseURL", "")
        aiModel = value("aiModel", "")
        aiSystemPrompt = value("aiSystemPrompt", "")
        aiToolAccess = AIToolAccess(rawValue: value("aiToolAccess", "")) ?? .confirm
        aiHistoryCount = min(200, max(0, value("aiHistoryCount", 50)))
    }

    /// Every adjustable part of the background's look at once, for presets and saved looks.
    var backgroundStyle: BackgroundStyle {
        get {
            BackgroundStyle(blur: blur, saturation: backgroundSaturation, dim: dim, glassStrength: glassStrength,
                            temperature: backgroundTemperature, tintHue: backgroundTintHue, tint: backgroundTint,
                            grain: backgroundGrain, vignette: backgroundVignette)
        }
        set {
            let style = newValue.clamped
            if blur != style.blur { blur = style.blur }
            if backgroundSaturation != style.saturation { backgroundSaturation = style.saturation }
            if dim != style.dim { dim = style.dim }
            if glassStrength != style.glassStrength { glassStrength = style.glassStrength }
            if backgroundTemperature != style.temperature { backgroundTemperature = style.temperature }
            if backgroundTintHue != style.tintHue { backgroundTintHue = style.tintHue }
            if backgroundTint != style.tint { backgroundTint = style.tint }
            if backgroundGrain != style.grain { backgroundGrain = style.grain }
            if backgroundVignette != style.vignette { backgroundVignette = style.vignette }
        }
    }

    /// The animation for one of the launcher's transitions: `standard` unless a curve is chosen,
    /// which then runs for `duration` seconds (the animation speed setting still scales it).
    func motion(_ standard: Animation, duration: Double) -> Animation {
        motionCurve?.animation(duration: duration) ?? standard
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
        UserDefaults.app.stringArray(forKey: "extraAppFolders") ?? []
    }
}

/// The app's own language, set by overriding `AppleLanguages` for LaunchUS only.
/// Takes effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
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
