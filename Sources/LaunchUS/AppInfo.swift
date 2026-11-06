import AppKit
import SwiftUI

/// What the info card shows about one app, read from its bundle.
struct AppInfo: Equatable {
    enum Architecture: Equatable {
        case appleSilicon, intel, universal

        var title: String {
            switch self {
            case .appleSilicon: String(localized: "Apple 芯片")
            case .universal: String(localized: "通用（Apple 芯片与 Intel）")
            case .intel:
                #if arch(arm64)
                String(localized: "Intel（通过 Rosetta 运行）")
                #else
                String(localized: "Intel")
                #endif
            }
        }
    }

    var version: String?
    var architecture: Architecture?
    var fromAppStore = false

    nonisolated static func read(_ url: URL) -> AppInfo {
        let contents = url.appendingPathComponent("Contents")
        let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
            ?? NSDictionary(contentsOf: url.appendingPathComponent("WrappedBundle/Info.plist"))
        var info = AppInfo()
        let short = plist?["CFBundleShortVersionString"] as? String
        let build = plist?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: info.version = "\(s)（\(b)）"
        case let (s?, _): info.version = s
        case let (nil, b?): info.version = b
        default: break
        }
        // Read from the executable's Mach-O headers.
        if let kinds = Bundle(url: url)?.executableArchitectures?.map(\.intValue) {
            info.architecture = architecture(kinds)
        }
        info.fromAppStore = FileManager.default.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path)
        return info
    }

    nonisolated static func architecture(_ kinds: [Int]) -> Architecture? {
        let arm = kinds.contains(NSBundleExecutableArchitectureARM64)
        let intel = kinds.contains(NSBundleExecutableArchitectureX86_64)
        switch (arm, intel) {
        case (true, true): return .universal
        case (true, false): return .appleSilicon
        case (false, true): return .intel
        default: return nil
        }
    }
}

/// The info card: version, chip, size, where it came from and how it's used.
struct AppInfoCard: View {
    let model: LauncherModel
    let app: AppItem

    @State private var info: AppInfo?
    @State private var size: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(model: model, app: app, title: app.name, subtitle: app.bundleID)
            VStack(alignment: .leading, spacing: 8) {
                row(String(localized: "版本"), info?.version ?? "—")
                if let arch = info?.architecture { row(String(localized: "芯片"), arch.title) }
                row(String(localized: "大小"), size.map(Uninstaller.format) ?? String(localized: "正在计算…"))
                if let info { row(String(localized: "来源"), info.fromAppStore ? "App Store" : String(localized: "其他来源")) }
                if let added = app.addedDate {
                    row(String(localized: "安装时间"), added.formatted(date: .long, time: .omitted))
                }
                row(String(localized: "上次使用"), app.lastUsedDate.map(Self.relative) ?? String(localized: "没有记录"))
                if app.useCount > 0 { row(String(localized: "打开次数"), String(localized: "\(app.useCount) 次")) }
                row(String(localized: "位置"), app.url.path, selectable: true)
            }
            .font(.system(size: 13))
            HStack {
                Button(String(localized: "在访达中显示")) { model.sheet = nil; model.reveal(app.url.path) }
                if app.isRemovable {
                    Button(String(localized: "卸载…")) { model.sheet = .confirmTrash(app.id) }
                }
                Spacer()
                Button(String(localized: "好")) { model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .task(id: app.id) {
            let url = app.url
            let read = await Task.detached(priority: .userInitiated) { AppInfo.read(url) }.value
            info = read
            size = await Task.detached(priority: .utility) { Uninstaller.file(url).size }.value
        }
    }

    private func row(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Group {
                if selectable {
                    Text(verbatim: value).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                } else {
                    Text(verbatim: value)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .monospacedDigit()
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
