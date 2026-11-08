import AppKit
import SwiftUI
import UserNotifications

// MARK: - Quick actions

enum QuickAction: String, CaseIterable {
    case lock, screenshot, darkMode, mute, displaySleep, sleep, keepAwake, emptyTrash

    var title: String {
        switch self {
        case .lock: String(localized: "锁屏")
        case .screenshot: String(localized: "截屏")
        case .darkMode: String(localized: "深色模式")
        case .mute: String(localized: "静音")
        case .displaySleep: String(localized: "关闭显示器")
        case .sleep: String(localized: "睡眠")
        case .keepAwake: String(localized: "保持唤醒")
        case .emptyTrash: String(localized: "清空废纸篓")
        }
    }

    var symbol: String {
        switch self {
        case .lock: "lock.fill"
        case .screenshot: "camera.viewfinder"
        case .darkMode: "circle.lefthalf.filled"
        case .mute: "speaker.slash.fill"
        case .displaySleep: "display"
        case .sleep: "moon.zzz.fill"
        case .keepAwake: "cup.and.heat.waves.fill"
        case .emptyTrash: "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .lock: .blue
        case .screenshot: .teal
        case .darkMode: .indigo
        case .mute: .pink
        case .displaySleep: .cyan
        case .sleep: .purple
        case .keepAwake: .orange
        case .emptyTrash: .red
        }
    }

    /// Leaves the launcher first: the action is about the screen or the whole Mac.
    var closesLauncher: Bool { [.lock, .screenshot, .displaySleep, .sleep].contains(self) }
}

@MainActor @Observable
final class QuickActions {
    static let shared = QuickActions()

    private(set) var dark = QuickActions.systemIsDark()
    private(set) var muted = false
    private(set) var keepingAwake = false
    /// Emptying the Trash takes a second click within a few seconds.
    private(set) var trashArmed = false
    @ObservationIgnored private var caffeinate: Process?
    @ObservationIgnored private var disarm: DispatchWorkItem?

    func isOn(_ action: QuickAction) -> Bool {
        switch action {
        case .darkMode: dark
        case .mute: muted
        case .keepAwake: keepingAwake
        case .emptyTrash: trashArmed
        default: false
        }
    }

    func refresh() {
        dark = Self.systemIsDark()
        Self.osascript("output muted of (get volume settings)") { [weak self] out in self?.muted = out == "true" }
    }

    func perform(_ action: QuickAction) {
        switch action {
        case .lock:
            Self.lockScreen()
        case .screenshot:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        case .darkMode:
            dark.toggle()
            Self.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode") { [weak self] _ in
                self?.dark = Self.systemIsDark()
            }
        case .mute:
            muted.toggle()
            Self.osascript("set volume output muted (not (output muted of (get volume settings)))\noutput muted of (get volume settings)") { [weak self] out in
                self?.muted = out == "true"
            }
        case .displaySleep:
            Self.run("/usr/bin/pmset", ["displaysleepnow"])
        case .sleep:
            Self.run("/usr/bin/pmset", ["sleepnow"])
        case .keepAwake:
            if let caffeinate {
                caffeinate.terminate()
                self.caffeinate = nil
                keepingAwake = false
            } else {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                p.arguments = ["-di", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
                p.terminationHandler = { _ in Task { @MainActor in QuickActions.shared.caffeinateEnded(p) } }
                if (try? p.run()) != nil {
                    caffeinate = p
                    keepingAwake = true
                }
            }
        case .emptyTrash:
            disarm?.cancel()
            if trashArmed {
                trashArmed = false
                Self.osascript("tell application \"Finder\" to empty trash") { _ in }
            } else {
                trashArmed = true
                let work = DispatchWorkItem { [weak self] in self?.trashArmed = false }
                disarm = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }
        }
    }

    private func caffeinateEnded(_ p: Process) {
        guard caffeinate === p else { return }
        caffeinate = nil
        keepingAwake = false
    }

    private static func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        try? p.run()
    }

    private static func osascript(_ script: String, done: @escaping @MainActor (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in done(out) }
        }
        try? p.run()
    }

    /// The same as  › Lock Screen.
    private static func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        unsafeBitCast(symbol, to: Lock.self)()
    }
}

struct ActionsWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize

    static func actions(_ size: WidgetItem.Size) -> [QuickAction] {
        size == .small ? [.lock, .screenshot, .darkMode, .mute] : QuickAction.allCases
    }

    static func shape(_ size: WidgetItem.Size) -> (columns: Int, rows: Int) {
        switch size {
        case .small: (2, 2)
        case .medium: (4, 2)
        case .large: (2, 4)
        }
    }

    static func gap(_ card: CGSize) -> CGFloat { min(card.width, card.height) * 0.05 }

    static func action(at point: CGPoint, size: WidgetItem.Size, card: CGSize) -> QuickAction? {
        let list = actions(size)
        let (c, r) = shape(size)
        let local = ToolGrid.local(point, card: card)
        let cells = ToolGrid.cells(count: list.count, columns: c, rows: r, in: ToolGrid.content(card).size, gap: gap(card))
        return cells.firstIndex { $0.contains(local) }.map { list[$0] }
    }

    var body: some View {
        let list = Self.actions(size)
        let (c, r) = Self.shape(size)
        let area = ToolGrid.content(card).size
        let cells = ToolGrid.cells(count: list.count, columns: c, rows: r, in: area, gap: Self.gap(card))
        let state = QuickActions.shared
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(list, cells)), id: \.0) { action, cell in
                tile(action, on: state.isOn(action), cell: cell)
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: cell.minX, y: cell.minY)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .onAppear { state.refresh() }
    }

    private func tile(_ action: QuickAction, on: Bool, cell: CGRect) -> some View {
        let radius = min(cell.width, cell.height) * 0.28
        let title = action == .emptyTrash && on ? String(localized: "再点一次") : action.title
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(on ? AnyShapeStyle(action.tint.opacity(0.9)) : AnyShapeStyle(.primary.opacity(0.1)))
            .overlay {
                if size == .large {
                    HStack(spacing: unit * 0.1) {
                        icon(action, on: on, side: cell.height * 0.5)
                        Text(title).font(.system(size: unit * 0.13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, cell.height * 0.22)
                } else {
                    VStack(spacing: cell.height * 0.06) {
                        icon(action, on: on, side: min(cell.width, cell.height) * 0.42)
                        if size == .medium {
                            Text(title).font(.system(size: unit * 0.09, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                    .padding(cell.height * 0.06)
                }
            }
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .help(action.title)
    }

    private func icon(_ action: QuickAction, on: Bool, side: CGFloat) -> some View {
        ZStack {
            Circle().fill(on ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(action.tint))
            Image(systemName: action.symbol).font(.system(size: side * 0.45, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: side, height: side)
    }
}
