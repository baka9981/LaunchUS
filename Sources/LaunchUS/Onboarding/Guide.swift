import AppKit
import SwiftUI

/// First-run walkthrough over the launcher: a few cards, each with a small looping animation.
struct GuideView: View {
    let model: LauncherModel
    private var step: Int {
        get { model.guideStep }
        nonmutating set { model.guideStep = newValue }
    }
    @State private var forward = true

    private static let steps = 9

    var body: some View {
        let settings = model.settings
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch step {
                    case 0: GuideWelcome(style: settings.appIcon)
                    case 1: GuideMode(settings: settings)
                    case 2: GuidePinch()
                    case 3: GuideFolder()
                    case 4: GuideEdit()
                    case 5: GuideRightClick()
                    case 6: GuideSearch()
                    case 7: GuideCustomize()
                    default: GuideHidden()
                    }
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? 60 : -60).combined(with: .opacity),
                    removal: .offset(x: forward ? -60 : 60).combined(with: .opacity)))
            }
            .frame(width: 460, height: 210)
            .clipped()

            VStack(spacing: 8) {
                Text(title(settings)).font(.system(size: 22, weight: .semibold))
                Text(detail(settings))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 400, height: 96, alignment: .top)
            .id("text\(step)")
            .transition(.opacity)

            HStack(spacing: 6) {
                ForEach(0..<Self.steps, id: \.self) { i in
                    Capsule()
                        .fill(Color.primary.opacity(i == step ? 0.7 : 0.18))
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .padding(.bottom, 18)

            HStack {
                if step < Self.steps - 1 {
                    Button(String(localized: "跳过")) { model.finishGuide() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                if step > 0 {
                    Button(String(localized: "上一步")) { go(-1) }.controlSize(.large)
                }
                Button(step == Self.steps - 1 ? String(localized: "开始使用") : String(localized: "下一步")) {
                    step == Self.steps - 1 ? model.finishGuide() : go(1)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(width: 520)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { step += delta }
        // Whoever saw the right-click card doesn't need the same hint after their first swipe.
        if step == 5 { Tip.rightClick.markShown() }
    }

    private func title(_ settings: Settings) -> String {
        switch step {
        case 0: String(localized: "欢迎使用 LaunchUS")
        case 1: String(localized: "选择显示方式")
        case 2: String(localized: "随时打开")
        case 3: String(localized: "拖动整理")
        case 4: String(localized: "编辑与多选")
        case 5: String(localized: "右键打开更多")
        case 6: String(localized: "快速搜索")
        case 7: String(localized: "按你的习惯来")
        default: String(localized: "隐藏的 App")
        }
    }

    private func detail(_ settings: Settings) -> String {
        switch step {
        case 0: String(localized: "熟悉的启动台回来了：所有 App 一屏排开，翻页、文件夹、搜索都在这里。完全免费。")
        case 1: String(localized: "选一种开始用，点一下就能看到效果。之后可以在设置最上面的方案栏里新建更多方案，比如一套全屏、一套窗口，随时切换。")
        case 2: String(localized: "按 \(settings.hotKey?.display ?? HotKeySpec.default.display) 打开。也可以在设置里打开触控板捏合（拇指和三指）、F4 键或触发角。")
        case 3: String(localized: "把一个 App 拖到另一个上面就会建立文件夹。拖到屏幕边缘可以翻到别的页面。")
        case 4: String(localized: "长按图标或按住 ⌥ 进入编辑模式，按住 ⌘ 点击可以多选。右键选「编辑…」可以改名称、图标和标签，也可以移动或卸载。")
        case 5: String(localized: "在空白处点右键，可以打开设置，新建启动项，整理文件夹，切换排序和布局方案。右键 App 或文件夹还有各自的操作。")
        case 6: String(localized: "直接打字即可搜索，支持拼音和首字母，比如输入「wx」找到微信。输入 # 按标签筛选，输入 128*3 直接算出结果。")
        case 7: String(localized: "⋯ 菜单里可以新建启动项（网址、文件或脚本），也能切换多套布局方案。编辑时把图标拖到屏幕底边，可以放进程序坞或访达。")
        default: String(localized: "右键 App 选择「隐藏」，它就不会出现在网格里。最后一个分页圆点后面藏着入口，验证后才能看到。入口和暗号可在设置 › App 中调整。")
        }
    }
}

// MARK: - Illustrations

private let tileColors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .indigo, .yellow]

private struct Tile: View {
    var color: Color
    var size: CGFloat = 56
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
    }
}

private struct GuideWelcome: View {
    let style: AppIconStyle
    @State private var shown = false

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * .pi
                Tile(color: tileColors[i], size: 34)
                    .offset(x: shown ? cos(angle) * 150 : 0, y: shown ? sin(angle) * 70 : 0)
                    .opacity(shown ? 0.9 : 0)
            }
            Image(nsImage: IconArt.image(style, size: 256))
                .resizable()
                .frame(width: 120, height: 120)
                .scaleEffect(shown ? 1 : 0.6)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.1)) { shown = true } }
    }
}

/// The first layout profile's way of showing: full screen or window, applied at once.
private struct GuideMode: View {
    @Bindable var settings: Settings

    var body: some View {
        HStack(spacing: 12) {
            ForEach(DisplayMode.allCases, id: \.self) { mode in
                DisplayModeCard(mode: mode, selected: settings.displayMode == mode, thumbHeight: 112) {
                    settings.displayMode = mode
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

/// A trackpad with four fingertips pinching together, over and over.
private struct GuidePinch: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                .frame(width: 260, height: 170)
            PhaseAnimator([false, true, true, false]) { pinched in
                ZStack {
                    let fingers: [CGPoint] = [CGPoint(x: -70, y: 45), CGPoint(x: -20, y: -45),
                                              CGPoint(x: 25, y: -50), CGPoint(x: 70, y: -35)]
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: 26, height: 26)
                            .offset(x: pinched ? fingers[i].x * 0.25 : fingers[i].x,
                                    y: pinched ? fingers[i].y * 0.25 : fingers[i].y)
                    }
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                        .scaleEffect(pinched ? 1 : 0.3)
                        .opacity(pinched ? 1 : 0)
                }
            } animation: { _ in .easeInOut(duration: 0.7) }
        }
    }
}

/// One tile slides onto another and they become a folder.
private struct GuideFolder: View {
    enum Phase: CaseIterable { case apart, over, folder, hold }

    var body: some View {
        PhaseAnimator(Phase.allCases) { phase in
            HStack(spacing: 34) {
                Tile(color: tileColors[2]).opacity(0.5)
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 70, height: 70)
                        .scaleEffect(phase == .apart ? 0.8 : 1)
                        .opacity(phase == .apart ? 0 : 1)
                    Tile(color: tileColors[0], size: phase == .folder || phase == .hold ? 24 : 56)
                        .offset(x: phase == .folder || phase == .hold ? -14 : 0)
                    Tile(color: tileColors[1], size: phase == .folder || phase == .hold ? 24 : 56)
                        .offset(x: phase == .apart ? 90 : phase == .over ? 6 : 14,
                                y: phase == .over ? -6 : 0)
                        .scaleEffect(phase == .over ? 1.1 : 1)
                }
                .frame(width: 70)
                Tile(color: tileColors[3]).opacity(phase == .apart ? 0 : 0.5)
            }
        } animation: { phase in
            switch phase {
            case .apart: .easeInOut(duration: 0.5)
            case .over: .easeInOut(duration: 0.8)
            case .folder: .spring(response: 0.45, dampingFraction: 0.75)
            case .hold: .linear(duration: 1.2)
            }
        }
    }
}

/// Jiggling tiles, two of them picked.
private struct GuideEdit: View {
    var body: some View {
        PhaseAnimator([-2.5, 2.5]) { angle in
            HStack(spacing: 22) {
                ForEach(0..<4, id: \.self) { i in
                    Tile(color: tileColors[i + 4])
                        .rotationEffect(.degrees(i.isMultiple(of: 2) ? angle : -angle))
                        .overlay(alignment: .bottomTrailing) {
                            if i == 1 || i == 2 {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .offset(x: 5, y: 5)
                            }
                        }
                }
            }
        } animation: { _ in .easeInOut(duration: 0.13) }
    }
}

/// A pointer right-clicks empty space and the launcher's menu opens next to it.
private struct GuideRightClick: View {
    enum Phase: CaseIterable { case idle, press, open, hold }

    var body: some View {
        PhaseAnimator(Phase.allCases) { phase in
            let open = phase == .open || phase == .hold
            ZStack(alignment: .topLeading) {
                HStack(spacing: 18) {
                    ForEach(0..<3, id: \.self) { i in Tile(color: tileColors[i]).opacity(0.45) }
                }
                .frame(width: 400, height: 180)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 20))
                    .scaleEffect(phase == .press ? 0.85 : 1)
                    .offset(x: phase == .idle ? 250 : 200, y: phase == .idle ? 150 : 34)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array([("plus", "新建"), ("square.grid.3x3.topleft.filled", "整理"),
                                   ("eye", "视图"), ("gearshape", "设置…")].enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 8) {
                            Image(systemName: item.0).frame(width: 16)
                            Text(LocalizedStringKey(item.1))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(i == 3 && phase == .hold ? Color.accentColor : .clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(i == 3 && phase == .hold ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                }
                .padding(5)
                .frame(width: 128)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .scaleEffect(open ? 1 : 0.85, anchor: .topLeading)
                .opacity(open ? 1 : 0)
                .offset(x: 212, y: 44)
            }
            .frame(width: 400, height: 180)
        } animation: { phase in
            switch phase {
            case .idle: .easeInOut(duration: 0.6)
            case .press: .easeInOut(duration: 0.7)
            case .open: .spring(response: 0.3, dampingFraction: 0.8)
            case .hold: .linear(duration: 1.6)
            }
        }
    }
}

/// "wx" typed letter by letter, then the matching app.
private struct GuideSearch: View {
    var body: some View {
        PhaseAnimator([0, 1, 2, 3]) { typed in
            VStack(spacing: 24) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(String("wx".prefix(typed)))
                    Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 16)
                    Spacer()
                }
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .frame(width: 240, height: 34)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                VStack(spacing: 6) {
                    Tile(color: .green)
                        .overlay(Image(systemName: "message.fill").font(.system(size: 24)).foregroundStyle(.white))
                    Text("微信").font(.system(size: 12))
                }
                .opacity(typed >= 2 ? 1 : 0)
                .scaleEffect(typed >= 2 ? 1 : 0.8)
            }
        } animation: { typed in typed == 3 ? .linear(duration: 1.6) : .easeOut(duration: 0.45) }
    }
}

/// Launch items appear beside an app, then one of them gets a new icon.
private struct GuideCustomize: View {
    enum Phase: CaseIterable { case app, items, restyle, hold }

    var body: some View {
        PhaseAnimator(Phase.allCases) { phase in
            HStack(spacing: 22) {
                Tile(color: tileColors[0])
                    .overlay(Image(systemName: "safari.fill").font(.system(size: 26)).foregroundStyle(.white))
                ForEach(Array(["globe", "doc.fill", "terminal.fill"].enumerated()), id: \.offset) { i, symbol in
                    let restyled = i == 2 && (phase == .restyle || phase == .hold)
                    Tile(color: restyled ? tileColors[3] : .gray)
                        .overlay(Image(systemName: restyled ? "star.fill" : symbol)
                            .font(.system(size: 24)).foregroundStyle(.white))
                        .scaleEffect(phase == .app ? 0.6 : restyled ? 1.08 : 1)
                        .opacity(phase == .app ? 0 : 1)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(Double(i) * 0.08), value: phase)
                }
            }
        } animation: { phase in phase == .hold ? .linear(duration: 1.4) : .easeInOut(duration: 0.6) }
    }
}

/// Page dots, then a dashed one appearing after them.
private struct GuideHidden: View {
    enum Phase: CaseIterable { case dots, hover, unlocked, hold }

    var body: some View {
        PhaseAnimator(Phase.allCases) { phase in
            VStack(spacing: 30) {
                ZStack {
                    if phase == .unlocked || phase == .hold {
                        HStack(spacing: 10) {
                            ForEach(0..<3, id: \.self) { i in Tile(color: tileColors[i + 5], size: 44) }
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    } else {
                        Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .frame(height: 70)
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(Color.primary.opacity(i == 0 ? 0.6 : 0.2)).frame(width: 9, height: 9)
                    }
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 1.6]))
                        .frame(width: 9, height: 9)
                        .opacity(phase == .dots ? 0 : 1)
                        .overlay {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 20))
                                .offset(x: phase == .dots ? 40 : 9, y: phase == .dots ? 24 : 12)
                        }
                }
            }
        } animation: { phase in phase == .hold ? .linear(duration: 1.4) : .easeInOut(duration: 0.6) }
    }
}
