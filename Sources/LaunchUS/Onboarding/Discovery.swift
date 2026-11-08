import AppKit
import SwiftUI

// How features reach people: the walkthrough (Guide.swift) for new users, the
// "新功能" card once after an upgrade, and one-time tips at the moment a feature helps.

/// The "新功能" card, shown once the next time the launcher opens after an upgrade.
enum WhatsNew {
    /// Bump when `features` changes; bug-fix releases keep it, so the card doesn't come back.
    static let edition = 2
    private static let key = "whatsNewSeen"

    struct Feature: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        /// Takes the user straight to the feature; `nil` for gestures that just need explaining.
        var action: (@MainActor (LauncherModel) -> Void)?
        var id: String { symbol }
    }

    @MainActor static var features: [Feature] {
        [
            Feature(symbol: "arrow.down.doc", title: String(localized: "拖文件到图标上"),
                    detail: String(localized: "用这个 App 打开，和程序坞一样")),
            Feature(symbol: "plus.forwardslash.minus", title: String(localized: "计算"),
                    detail: String(localized: "在搜索栏输入 128*3，按 ↩ 复制结果")),
            Feature(symbol: "command", title: String(localized: "⌘1–9 打开常用 App"),
                    detail: String(localized: "最近一行的前 9 个，右键可以固定"),
                    action: { $0.finishWhatsNew(); $0.openSettings(.display) }),
            Feature(symbol: "arrow.up.left.and.arrow.down.right", title: String(localized: "图标大小"),
                    detail: String(localized: "设置 › 显示方式"),
                    action: { $0.finishWhatsNew(); $0.openSettings(.display) }),
            Feature(symbol: "drop", title: String(localized: "液态玻璃文件夹"),
                    detail: String(localized: "文件夹透出后面的内容"),
                    action: { $0.finishWhatsNew(); $0.openSettings(.appearance) }),
            Feature(symbol: "hare", title: String(localized: "动画速度"),
                    detail: String(localized: "标准、快速或关闭"),
                    action: { $0.finishWhatsNew(); $0.openSettings(.appearance) }),
            Feature(symbol: "moon.zzz", title: String(localized: "久未打开的 App"),
                    detail: String(localized: "淡化或一次选中，统一整理"),
                    action: { $0.finishWhatsNew(); $0.openSettings(.appearance) }),
            Feature(symbol: "hand.pinch", title: String(localized: "4 指或 5 指捏合"),
                    detail: String(localized: "两种手势都能打开"),
                    action: { $0.finishWhatsNew(); $0.openSettings(.general) }),
        ]
    }

    /// People upgrading from a build without the card count as having seen edition 0.
    static var isPending: Bool {
        let defaults = UserDefaults.app
        return defaults.bool(forKey: "didShowGuide") && defaults.integer(forKey: key) < edition
    }

    /// Also called after the walkthrough: new users already get the current features there.
    static func markSeen() { UserDefaults.app.set(edition, forKey: key) }
}

/// A hint shown once, at the moment it's useful.
enum Tip: String {
    case dragOut, frequentRow, launchItem, rightClick, hiddenDot
    /// Asks for suggestions the first time the launcher opens each day; activated Macs can turn
    /// it off on the 激活 page.
    case feedback

    private static let key = "shownTips"
    private static let feedbackDayKey = "feedbackTipDay"
    nonisolated(unsafe) private static var shown = Set(UserDefaults.app.stringArray(forKey: key) ?? [])

    var wasShown: Bool {
        if self == .feedback { return UserDefaults.app.string(forKey: Self.feedbackDayKey) == Self.today }
        return Self.shown.contains(rawValue)
    }

    func markShown() {
        if self == .feedback { UserDefaults.app.set(Self.today, forKey: Self.feedbackDayKey); return }
        Self.shown.insert(rawValue)
        UserDefaults.app.set(Array(Self.shown).sorted(), forKey: Self.key)
    }

    private static var today: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Whether today's reminder is due: always before activating, else unless turned off.
    @MainActor static var feedbackDue: Bool {
        // Not in demo runs (website pictures); LAUNCHUS_SHEET=tip:feedback shows it there.
        if ProcessInfo.processInfo.environment["LAUNCHUS_DEMO"] != nil { return false }
        return !Tip.feedback.wasShown && (!License.shared.isActivated || UserDefaults.app.object(forKey: Settings.feedbackReminderKey) as? Bool ?? true)
    }

    /// Launches through LaunchUS before the frequent row is suggested.
    static let frequentRowAfter = 5

    @MainActor func text(_ settings: Settings) -> String {
        switch self {
        case .dragOut:
            settings.displayMode == .window
                ? String(localized: "小技巧：把图标拖出窗口，可以放进程序坞或访达")
                : String(localized: "小技巧：把图标拖到屏幕底边，可以放进程序坞或访达")
        case .frequentRow: String(localized: "想把最近打开的 App 放在最上面？可以开启「最近一行」")
        case .launchItem: String(localized: "没找到？网址、文件和脚本也能做成启动项")
        case .rightClick: String(localized: "小技巧：在空白处点右键，可以打开设置和更多选项")
        case .hiddenDot: String(localized: "已隐藏。想找回来，点页面圆点右边的虚线小圆点")
        case .feedback: String(localized: "用得怎么样？欢迎给我们一些建议和反馈")
        }
    }

    var actionTitle: String? {
        switch self {
        case .dragOut: nil
        case .frequentRow: String(localized: "开启")
        case .launchItem: String(localized: "新建启动项…")
        case .rightClick: String(localized: "打开设置")
        case .hiddenDot: String(localized: "看看")
        case .feedback: String(localized: "写反馈")
        }
    }

    @MainActor func perform(_ model: LauncherModel) {
        switch self {
        case .dragOut: break
        case .frequentRow: model.settings.showFrequent = true
        case .launchItem:
            model.query = ""
            model.sheet = .editCustom(nil)
        case .rightClick: model.openSettings()
        case .hiddenDot: model.revealHidden()
        case .feedback: model.openSettings(.feedback)
        }
    }
}

extension LauncherModel {
    /// After the launcher appears: the "新功能" card, or else a tip that's become relevant.
    func presentPendingIntro() {
        guard !showGuide, sheet == nil, !showSettings else { return }
        if WhatsNew.isPending {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { showWhatsNew = true }
        } else if !showsFrequentRow, settings.pageStyle == .scroll, RecentLaunches.load().count >= Tip.frequentRowAfter {
            offerTip(.frequentRow)
        } else if Tip.feedbackDue {
            offerTip(.feedback)
        }
    }

    func finishWhatsNew() {
        WhatsNew.markSeen()
        withAnimation(.easeOut(duration: 0.2)) { showWhatsNew = false }
        focusRequest += 1
    }

    /// Shows a tip unless it was shown before or something else has the user's attention.
    func offerTip(_ tip: Tip) {
        // A tip still on screen gives way: the new one is about what was just done (hiding an
        // app right after the first right-click would otherwise never get its tip).
        guard !tip.wasShown, self.tip != tip, isPresented, !showGuide, !showWhatsNew else { return }
        tip.markShown()
        withAnimation(.easeOut(duration: 0.2)) { self.tip = tip }
        DispatchQueue.main.asyncAfter(deadline: .now() + (tip == .hiddenDot || tip == .feedback ? 12 : 8)) { [weak self] in
            guard let self, self.tip == tip else { return }
            dismissTip()
        }
    }

    func dismissTip() {
        withAnimation(.easeIn(duration: 0.25)) { tip = nil }
    }
}

struct WhatsNewView: View {
    let model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 10)
            Text(String(localized: "LaunchUS 新功能")).font(.system(size: 22, weight: .semibold))
            Text(String(localized: "点一项直接去试试。以后可以在设置 › 通用 › 帮助里再看使用引导。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 18)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(WhatsNew.features) { feature in
                    WhatsNewRow(feature: feature) { feature.action?(model) }
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "好的")) { model.finishWhatsNew() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: 580)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    }
}

private struct WhatsNewRow: View {
    let feature: WhatsNew.Feature
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feature.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(.system(size: 13, weight: .semibold))
                Text(feature.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if feature.action != nil {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(hovering && feature.action != nil ? 0.07 : 0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// A tip over the page dots, with an optional button and a close button.
struct TipToast: View {
    let model: LauncherModel
    let tip: Tip
    let windowed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tip == .feedback ? "bubble.left.and.text.bubble.right.fill" : "lightbulb.fill")
                .foregroundStyle(tip == .feedback ? Color.accentColor : .yellow)
            Text(tip.text(model.settings)).font(.system(size: 13, weight: .medium))
            if let title = tip.actionTitle {
                Button(title) {
                    model.dismissTip()
                    tip.perform(model)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }
            Button { model.dismissTip() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 8)
        .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.55)), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .fixedSize()
    }
}
