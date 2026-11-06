import SwiftUI

/// Capsule search field: magnifier on the left, "⋯" menu on the right.
struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    /// Chatting with AI: the field writes the next message.
    var chatting = false
    /// Builds the "⋯" menu.
    let menu: () -> NSMenu
    @State private var composing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: chatting ? "sparkles" : "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
            ZStack(alignment: .leading) {
                if text.isEmpty && !composing {
                    Text(chatting ? "继续问…" : "搜索应用")
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
            .trackingComposition($composing)
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
    var chatting = false
    let menu: () -> NSMenu
    @State private var composing = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: chatting ? "sparkles" : text.isEmpty ? "square.grid.3x3" : "magnifyingglass")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 26)
            ZStack(alignment: .leading) {
                if text.isEmpty && !composing {
                    Text(chatting ? "继续问…" : "应用程序")
                        .foregroundStyle(chatting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.8)))
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .accessibilityLabel(String(localized: "搜索应用"))
                    .textFieldStyle(.plain)
                    .focused(focused)
            }
            .font(.system(size: 24, weight: .regular))
            .trackingComposition($composing)
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
    }
}

/// Window mode's category tabs, the system Apps window's groups spread across the width.
/// No "all" tab: clicking the picked one again shows everything.
struct CategoryBar: View {
    let model: LauncherModel

    var body: some View {
        let tabs = model.categoryTabs
        // Spread out when they fit (they do in Chinese); otherwise a row that scrolls.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                ForEach(tabs, id: \.key) { tab($0.title, key: $0.key).frame(maxWidth: .infinity) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs, id: \.key) { tab($0.title, key: $0.key) }
                }
            }
        }
    }

    private func tab(_ title: String, key: String) -> some View {
        let selected = model.categoryFilter == key
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { model.categoryFilter = selected ? nil : key }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.8)))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                // A light veil with a hairline shadow, like the system Apps window's tabs: faint on dark glass, an outlined chip on light.
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.primary.opacity(0.14) : Color.white.opacity(0.28))
                        .shadow(color: .black.opacity(selected ? 0 : 0.12), radius: 1, y: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// Tag suggestions under the search field while typing "#…", the offer to keep a tag
/// search as a smart folder, or the tabs of the lists space opens.
struct TagBar: View {
    let model: LauncherModel

    var body: some View {
        HStack(spacing: 6) {
            let candidates = model.tagCandidates
            if let current = model.spaceList {
                // The lists space opens; space or ←/→ moves between them, or click one.
                ForEach(SpaceShortcut.allCases, id: \.self) { list in
                    Chip(title: list.title, selected: list == current) {
                        model.spaceList = list
                        model.focusRequest += 1
                    }
                }
            } else if !candidates.isEmpty {
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

extension View {
    /// Keeps `composing` true while an input method has uncommitted text (pinyin before a
    /// candidate is picked) in the focused field. That text isn't in the field's binding yet, so
    /// a placeholder drawn for an empty binding would sit on top of it. Marked text lives in the
    /// field editor's text storage, whose edits are the only signal; it's read once they settle.
    func trackingComposition(_ composing: Binding<Bool>) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification)) { _ in
            DispatchQueue.main.async {
                let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                let marked = editor?.isFieldEditor == true && editor?.hasMarkedText() == true
                if composing.wrappedValue != marked { composing.wrappedValue = marked }
            }
        }
    }
}
