import SwiftUI

/// Capsule search field: magnifier on the left, "⋯" menu on the right.
struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    /// Builds the "⋯" menu.
    let menu: () -> NSMenu

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("搜索应用")
                        .foregroundStyle(.white.opacity(0.5))
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .accessibilityLabel(String(localized: "搜索应用"))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused(focused)
            }
            .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "清除"))
            }
            MenuButton(make: menu) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .fixedSize()
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(SearchFieldGlass(liquid: Settings.shared.liquidGlass))
    }
}

/// Liquid glass like the folder tiles when that's on; otherwise the smoked capsule.
private struct SearchFieldGlass: ViewModifier {
    let liquid: Bool

    func body(content: Content) -> some View {
        if liquid {
            content.glassEffect(.clear.interactive(), in: Capsule())
        } else {
            content
                .background(.black.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
        }
    }
}

extension EnvironmentValues {
    /// True in window mode, where the launcher is a light/dark glass panel instead of the wallpaper.
    @Entry var windowedStyle = false
}

/// Window mode's header, like the system Apps window: a large search field and the ⋯ menu.
struct WindowHeader: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let menu: () -> NSMenu

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: text.isEmpty ? "square.grid.3x3" : "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("应用程序")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .accessibilityLabel(String(localized: "搜索应用"))
                    .textFieldStyle(.plain)
                    .focused(focused)
            }
            .font(.system(size: 26, weight: .regular))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            MenuButton(make: menu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
    }
}

/// Window mode's category tabs (全部 / 开发工具 / 社交 …).
struct CategoryBar: View {
    let model: LauncherModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tab(String(localized: "全部"), key: nil)
                ForEach(model.categoryTabs, id: \.key) { tab($0.title, key: $0.key) }
            }
            .padding(.horizontal, 2)
        }
    }

    private func tab(_ title: String, key: String?) -> some View {
        let selected = model.categoryFilter == key
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { model.categoryFilter = key }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Color.primary.opacity(selected ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PageDots: View {
    let count: Int
    let current: Int
    /// Secret entrance: an invisible extra dot after the last one.
    var phantom: (() -> Void)?
    let select: (Int) -> Void
    @Environment(\.windowedStyle) private var windowed

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { page in
                Circle()
                    .fill(windowed ? Color.primary.opacity(page == current ? 0.6 : 0.2) : .white.opacity(page == current ? 0.95 : 0.35))
                    .frame(width: 8, height: 8)
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture { select(page) }
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "第 \(page + 1) 页"))
                    .accessibilityAddTraits(page == current ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { select(page) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .opacity(count > 1 ? 1 : 0)
        // Outside the stack so the real dots stay centred.
        .overlay(alignment: .trailing) {
            if let phantom { PhantomDot(action: phantom).offset(x: 20) }
        }
    }
}

/// Tag suggestions under the search field while typing "#…", or the offer to keep a tag
/// search as a smart folder.
struct TagBar: View {
    let model: LauncherModel

    var body: some View {
        HStack(spacing: 6) {
            let candidates = model.tagCandidates
            if !candidates.isEmpty {
                ForEach(candidates, id: \.self) { tag in
                    Chip(title: "#" + tag) { model.completeTag(tag) }
                }
            } else if !model.completeQueryTags.isEmpty {
                Chip(title: String(localized: "存为智能文件夹"), systemImage: "folder.badge.plus") {
                    model.sheet = .editSmartFolder(nil, query: model.query.trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }
}

struct Chip: View {
    let title: String
    var systemImage: String?
    var selected = false
    let action: () -> Void
    @Environment(\.windowedStyle) private var windowed

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 12))
            .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white.opacity(0.9)))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(windowed ? Color.primary.opacity(selected ? 0.16 : 0.07) : .white.opacity(selected ? 0.3 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(windowed ? Color.primary.opacity(0.1) : .white.opacity(0.22), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
