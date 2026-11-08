import SwiftUI

/// Over a folder just picked with the multi-select key: it stays picked (the ticked option, or
/// Esc / a click elsewhere), or is let go and opened to pick apps inside. A small glass capsule pointing at the folder; Esc or a click elsewhere drops it.
struct FolderPickBubble: View {
    let model: LauncherModel
    let windowed: Bool
    /// Below the folder instead of above it (no room above).
    let below: Bool

    var body: some View {
        VStack(spacing: 0) {
            if below, showsPointer { pointer.rotationEffect(.degrees(180)) }
            HStack(spacing: 2) {
                option(String(localized: "已选中文件夹"), symbol: "checkmark.circle.fill", accent: true) {
                    model.resolveFolderPick(open: false)
                }
                Rectangle()
                    .fill(foreground.opacity(0.18))
                    .frame(width: 1, height: 18)
                option(String(localized: "打开并选择里面的 App"), symbol: "folder", accent: false) {
                    model.resolveFolderPick(open: true)
                }
            }
            .padding(4)
            .modifier(BubbleGlass(windowed: windowed, liquid: model.settings.liquidGlass))
            if !below, showsPointer { pointer }
        }
        .foregroundStyle(foreground)
        .fixedSize()
    }

    private var foreground: Color { windowed ? .primary : .white }
    /// Liquid glass has no flat colour for a notch to match.
    private var showsPointer: Bool { !model.settings.liquidGlass }

    /// The little notch pointing at the folder.
    private var pointer: some View {
        Triangle()
            .fill(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.5)))
            .frame(width: 14, height: 7)
    }

    private func option(_ title: String, symbol: String, accent: Bool, action: @escaping () -> Void) -> some View {
        BubbleOption(title: title, symbol: symbol, accent: accent, windowed: windowed, action: action)
    }
}

private struct BubbleOption: View {
    let title: String
    let symbol: String
    let accent: Bool
    let windowed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(accent ? .palette : .monochrome)
                    .foregroundStyle(accent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary),
                                     accent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill((windowed ? Color.primary : .white).opacity(hovering ? 0.16 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct BubbleGlass: ViewModifier {
    let windowed: Bool
    let liquid: Bool

    func body(content: Content) -> some View {
        if liquid {
            content
                .glassEffect(windowed ? .regular : .regular.tint(.black.opacity(0.25)), in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        } else {
            content
                .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.5)), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
