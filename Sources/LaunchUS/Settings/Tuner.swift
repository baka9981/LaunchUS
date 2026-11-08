import SwiftUI

/// Which tuning panel is open in place of the settings card.
enum Tuner: Hashable {
    case background, motion
}

/// A narrow panel at the screen's edge for fine-tuning one part of the look while watching it on
/// the launcher itself, so the detailed sliders don't crowd the settings card.
struct TunerPanel: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    let tuner: Tuner

    static let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tuner == .background ? String(localized: "背景效果") : String(localized: "动画曲线"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(String(localized: "完成")) { model.closeSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tuner {
                    case .background: BackgroundTuner(settings: settings)
                    case .motion: MotionTuner(model: model, settings: settings)
                    }
                }
                .padding(18)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }
}

// MARK: - Background

private struct BackgroundTuner: View {
    @Bindable var settings: Settings
    @State private var naming = false
    @State private var name = ""

    private var style: BackgroundStyle { settings.backgroundStyle }
    private var picture: Bool { settings.background != .glass }

    private var selectedSaved: BackgroundStyle.Saved? {
        settings.savedBackgroundStyles.first { $0.style.matches(style) }
    }

    var body: some View {
        TunerGroup(title: String(localized: "样式")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)], spacing: 8) {
                ForEach(BackgroundStyle.presets) { preset in
                    StyleChip(title: preset.title, style: preset.style, selected: preset.style.matches(style)) {
                        apply(preset.style)
                    }
                }
                ForEach(settings.savedBackgroundStyles) { saved in
                    StyleChip(title: saved.name, style: saved.style, selected: saved.id == selectedSaved?.id) {
                        apply(saved.style)
                    }
                }
            }
            if naming {
                HStack(spacing: 6) {
                    TextField(String(localized: "样式名称"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button(String(localized: "保存"), action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(String(localized: "取消")) { naming = false }
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button(String(localized: "存为样式…")) {
                        name = String(localized: "我的样式 \(settings.savedBackgroundStyles.count + 1)")
                        naming = true
                    }
                    .disabled(selectedSaved != nil || BackgroundStyle.presets.contains { $0.style.matches(style) })
                    if let saved = selectedSaved {
                        Button(String(localized: "删除「\(saved.name)」"), role: .destructive) {
                            settings.savedBackgroundStyles.removeAll { $0.id == saved.id }
                        }
                    }
                }
                .controlSize(.small)
            }
        }

        TunerGroup(title: String(localized: "模糊与颜色")) {
            if picture {
                TunerSlider(title: String(localized: "模糊"),
                            value: Binding(get: { (settings.blur / 240).squareRoot() },
                                           set: { settings.blur = (240 * $0 * $0 * 10).rounded() / 10 }),
                            range: 0...1, standard: (38.0 / 240).squareRoot(),
                            text: "\(Int(settings.blur.rounded()))")
                TunerSlider(title: String(localized: "鲜艳度"), value: $settings.backgroundSaturation,
                            range: 0...2, standard: 1.05, text: percent(settings.backgroundSaturation))
            } else {
                TunerSlider(title: String(localized: "玻璃强度"), value: $settings.glassStrength,
                            range: 0.2...1, standard: 1, text: percent(settings.glassStrength))
            }
            TunerSlider(title: String(localized: "色温"), value: $settings.backgroundTemperature,
                        range: -1...1, standard: 0, text: signed(settings.backgroundTemperature)) {
                LinearGradient(colors: [BackgroundToning.cool, .gray.opacity(0.3), BackgroundToning.warm],
                               startPoint: .leading, endPoint: .trailing)
            }
            TunerSlider(title: String(localized: "色调"), value: $settings.backgroundTintHue,
                        range: 0...1, standard: 0.6, text: "\(Int((settings.backgroundTintHue * 360).rounded()))°") {
                LinearGradient(colors: stride(from: 0.0, through: 1, by: 1.0 / 12).map {
                    Color(hue: $0, saturation: 0.7, brightness: 0.85)
                }, startPoint: .leading, endPoint: .trailing)
            }
            .opacity(settings.backgroundTint > 0 ? 1 : 0.5)
            TunerSlider(title: String(localized: "着色"), value: $settings.backgroundTint,
                        range: 0...1, standard: 0, text: percent(settings.backgroundTint))
        }

        TunerGroup(title: String(localized: "明暗与质感")) {
            TunerSlider(title: String(localized: "暗度"), value: $settings.dim,
                        range: 0...0.6, standard: 0.2, text: percent(settings.dim / 0.6))
            TunerSlider(title: String(localized: "暗角"), value: $settings.backgroundVignette,
                        range: 0...1, standard: 0, text: percent(settings.backgroundVignette))
            TunerSlider(title: String(localized: "颗粒感"), value: $settings.backgroundGrain,
                        range: 0...1, standard: 0, text: percent(settings.backgroundGrain))
            Toggle(String(localized: "深色时加深背景"), isOn: $settings.darkenBackground)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        }

        HStack {
            Text(String(localized: "「色调」选颜色，「着色」决定染上多少。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "全部还原")) { apply(.standard) }
                .controlSize(.small)
                .disabled(style.matches(.standard))
        }
    }

    private func apply(_ style: BackgroundStyle) {
        naming = false
        withAnimation(.easeOut(duration: 0.25)) { settings.backgroundStyle = style }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.savedBackgroundStyles.append(.init(name: trimmed, style: style))
        naming = false
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func signed(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

/// A small swatch for a look: a sample gradient toned like the look, with its name under it.
private struct StyleChip: View {
    let title: String
    let style: BackgroundStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    LinearGradient(colors: [sample(0.35, 0.55, 0.9), sample(0.95, 0.6, 0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .blur(radius: min(6, style.blur / 20))
                    BackgroundToning(style: style, blends: true)
                    Color.black.opacity(style.dim)
                }
                .compositingGroup()
                .frame(height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension StyleChip {
    /// A sample colour with the look's saturation applied, mixed towards its own grey.
    private func sample(_ r: Double, _ g: Double, _ b: Double) -> Color {
        let grey = 0.2126 * r + 0.7152 * g + 0.0722 * b
        func mix(_ c: Double) -> Double { min(1, max(0, grey + (c - grey) * style.saturation)) }
        return Color(red: mix(r), green: mix(g), blue: mix(b))
    }
}

// MARK: - Motion

private struct MotionTuner: View {
    let model: LauncherModel
    @Bindable var settings: Settings

    var body: some View {
        TunerGroup(title: String(localized: "预设")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                CurveChip(title: String(localized: "系统弹簧"), curve: nil, selected: settings.motionCurve == nil) {
                    settings.motionCurve = nil
                }
                ForEach(MotionCurve.presets) { preset in
                    CurveChip(title: preset.title, curve: preset.curve, selected: settings.motionCurve == preset.curve) {
                        settings.motionCurve = preset.curve
                    }
                }
            }
        }
        TunerGroup(title: String(localized: "曲线")) {
            if let curve = settings.motionCurve {
                HStack {
                    Spacer()
                    CurveEditor(curve: Binding(get: { curve }, set: { settings.motionCurve = $0 }))
                    Spacer()
                }
                Text(String(localized: "拖动两个圆点调节。横向是时间，纵向是进度；超出方框的部分会冲过头再回来"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "系统弹簧按手势的快慢自然收尾，没有固定的曲线。选一个方案后就可以拖动曲线"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "从「缓出」开始调")) { settings.motionCurve = MotionCurve.presets.first?.curve }
                    .controlSize(.small)
            }
        }
        TunerGroup(title: String(localized: "速度")) {
            TunerSlider(title: String(localized: "倍速"),
                        value: Binding(get: { log2(settings.animationRate) },
                                       set: { settings.animationRate = (pow(2, $0) * 20).rounded() / 20 }),
                        range: log2(AnimationSpeed.rateRange.lowerBound)...log2(AnimationSpeed.rateRange.upperBound),
                        standard: 0, text: String(format: "%.2g×", settings.animationRate))
                .disabled(settings.animationsOff)
            Toggle(String(localized: "关闭动画"), isOn: $settings.animationsOff)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        }
        HStack {
            Button(model.pageCount > 1 && settings.browseStyle == .paged ? String(localized: "试试翻页和文件夹") : String(localized: "试试文件夹")) { tryMotion() }
                .disabled(settings.animationsOff)
            Spacer()
            Button(String(localized: "全部还原")) {
                settings.motionCurve = nil
                settings.animationRate = 1
                settings.animationsOff = false
            }
            .disabled(settings.motionCurve == nil && settings.animationSpeed == .standard)
        }
        .controlSize(.small)
    }

    /// Turns a page and back, then opens and closes a folder on screen, to see the motion on the real launcher.
    private func tryMotion() {
        let speed = settings.animationSpeed
        var delay = 0.0
        if model.pageCount > 1, settings.browseStyle == .paged, model.openFolderID == nil {
            let from = model.currentPage
            let to = from + 1 < model.pageCount ? from + 1 : from - 1
            model.goToPage(to)
            DispatchQueue.main.asyncAfter(deadline: .now() + speed.duration(0.9)) { model.goToPage(from) }
            delay = speed.duration(1.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            model.closeFolder()
            guard let id = visibleFolderID() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + speed.duration(model.openFolderID == nil ? 0 : 0.4)) {
                model.openFolder(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + speed.duration(1.1)) {
                    if model.openFolderID == id { model.closeFolder() }
                }
            }
        }
    }

    /// The first folder whose tile is on screen now.
    private func visibleFolderID() -> String? {
        let page = model.pages.indices.contains(model.currentPage) ? model.pages[model.currentPage] : []
        let candidates = settings.browseStyle == .paged ? page : model.pages.flatMap { $0 }
        for case .folder(let folder, _) in candidates where model.tileRect(ofFolder: folder.id) != nil {
            return folder.id
        }
        return nil
    }
}

/// A preset's name with a tiny drawing of its curve.
private struct CurveChip: View {
    let title: String
    let curve: MotionCurve?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Canvas { context, size in
                    var path = Path()
                    let inset: CGFloat = 3
                    let w = size.width - inset * 2, h = size.height - inset * 2
                    // A spring has no fixed curve: draw a gentle ease-out for it.
                    let c = curve ?? MotionCurve(x1: 0.2, y1: 1, x2: 0.3, y2: 1)
                    let lo = min(0, c.y1, c.y2), hi = max(1, c.y1, c.y2)
                    func pt(_ x: Double, _ y: Double) -> CGPoint {
                        CGPoint(x: inset + CGFloat(x) * w, y: inset + CGFloat((hi - y) / (hi - lo)) * h)
                    }
                    path.move(to: pt(0, 0))
                    path.addCurve(to: pt(1, 1), control1: pt(c.x1, c.y1), control2: pt(c.x2, c.y2))
                    context.stroke(path, with: .color(selected ? .accentColor : .secondary), lineWidth: 1.5)
                }
                .frame(width: 22, height: 18)
                Text(title).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Building blocks

private struct TunerGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Name, slider, value and a reset arrow on one line; `track` draws an optional colour scale under it.
private struct TunerSlider<Track: View>: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let standard: Double
    let text: String
    @ViewBuilder var track: () -> Track

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).frame(width: 52, alignment: .leading)
            VStack(spacing: 0) {
                Slider(value: $value, in: range).controlSize(.small)
                track()
                    .frame(height: 3)
                    .clipShape(Capsule())
                    .padding(.horizontal, 4)
            }
            Text(text)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Button {
                value = standard
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "还原"))
            .disabled(abs(value - standard) < 0.0005)
        }
    }
}

extension TunerSlider where Track == EmptyView {
    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, standard: Double, text: String) {
        self.init(title: title, value: value, range: range, standard: standard, text: text) { EmptyView() }
    }
}

/// The background's presets and saved looks as a menu, for the settings card.
struct BackgroundStylePicker: View {
    @Bindable var settings: Settings

    private var label: String {
        let style = settings.backgroundStyle
        return BackgroundStyle.presets.first { $0.style.matches(style) }?.title
            ?? settings.savedBackgroundStyles.first { $0.style.matches(style) }?.name
            ?? String(localized: "自定义")
    }

    var body: some View {
        Menu(label) {
            ForEach(BackgroundStyle.presets) { preset in
                Button(preset.title) { settings.backgroundStyle = preset.style }
            }
            if !settings.savedBackgroundStyles.isEmpty {
                Divider()
                ForEach(settings.savedBackgroundStyles) { saved in
                    Button(saved.name) { settings.backgroundStyle = saved.style }
                }
            }
        }
        .fixedSize()
    }
}
