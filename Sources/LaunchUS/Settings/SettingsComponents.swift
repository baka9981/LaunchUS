import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Building blocks

/// Why a row is greyed out: it only does something in another mode.
enum ModeNote {
    static var paged: String { String(localized: "仅在分页浏览时可用") }
    static var scroll: String { String(localized: "仅在滚动浏览时可用") }
    static var fullScreen: String { String(localized: "仅在全屏模式下可用") }
}

struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 14, weight: .semibold)).padding(.leading, 4)
            }
            content()
        }
    }
}

/// A rounded group of rows with hairlines between them.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0, !subview.containerValues.joinsRowAbove { Divider().padding(.horizontal, 14) }
                    subview
                }
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension ContainerValues {
    /// Belongs to the row above, so a card draws no hairline between them.
    @Entry var joinsRowAbove = false
}

/// A problem with the row above: why, and a button to fix it in System Settings.
struct SettingWarning: View {
    let text: String
    var openSettings: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let openSettings {
                Button(String(localized: "打开系统设置"), action: openSettings)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, -4)
        .padding(.bottom, 10)
        .containerValue(\.joinsRowAbove, true)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13))
                    if let info { InfoButton(text: info) }
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

/// ⓘ after a setting's name: click for the explanation. Tooltips alone don't show
/// in the launcher's panel, which never becomes the key window.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

struct MenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}
