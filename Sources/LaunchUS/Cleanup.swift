import AppKit
import SwiftUI

/// Two or more copies of the same app (same bundle ID) on this Mac.
struct DuplicateApp: Identifiable, Sendable {
    struct Copy: Identifiable, Sendable {
        let url: URL
        let version: String?
        let size: Int64
        let modified: Date?
        var id: String { url.path }
    }
    let bundleID: String
    let name: String
    let copies: [Copy]
    var id: String { bundleID }
}

/// Files in the user's Library named after an app that is no longer installed.
struct Leftover: Identifiable, Sendable {
    let bundleID: String
    let files: [Uninstaller.File]
    var id: String { bundleID }
    var size: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Finds duplicate apps and leftovers of removed apps. Only reads; nothing is deleted.
enum AppCleanup {
    nonisolated static func duplicates(of apps: [AppItem]) -> [DuplicateApp] {
        var seen = Set<String>()
        var found: [DuplicateApp] = []
        for app in apps {
            guard let bundleID = app.bundleID, seen.insert(bundleID).inserted else { continue }
            let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
                .map(\.standardizedFileURL)
                .filter { isStandalone($0.path) }
            let unique = Array(Set(copies))
            guard unique.count > 1 else { continue }
            found.append(DuplicateApp(bundleID: bundleID, name: app.name, copies: unique.map { url in
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return .init(url: url, version: info?["CFBundleShortVersionString"] as? String,
                             size: Uninstaller.file(url).size, modified: modified)
            }.sorted { $0.url.path < $1.url.path }))
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A copy someone installed, not one inside another app, the Trash, the system or a cache.
    nonisolated static func isStandalone(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/private/")
            || path.hasPrefix(home + "/.Trash/") || path.hasPrefix(home + "/Library/") || path.hasPrefix("/Volumes/") {
            return false
        }
        // Nested in another bundle: an ".app/" (or similar) before the last component.
        let parent = (path as NSString).deletingLastPathComponent
        return !parent.split(separator: "/").contains { part in
            ["app", "framework", "bundle", "xpc", "appex"].contains((part as NSString).pathExtension.lowercased())
        }
    }

    /// Where apps keep their files under ~/Library, by bundle ID. Containers are left out:
    /// listing them asks for permission to access other apps' data.
    nonisolated static let places = ["Application Support", "Caches", "Preferences", "Saved Application State",
                                     "HTTPStorages", "WebKit", "Logs", "Cookies"]

    nonisolated static func leftovers(installed: Set<String>) -> [Leftover] {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        var byID: [String: [Uninstaller.File]] = [:]
        for place in places {
            let folder = library.appendingPathComponent(place)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names {
                guard let id = bundleID(inName: name), !isKnown(id, installed: installed) else { continue }
                byID[id, default: []].append(Uninstaller.file(folder.appendingPathComponent(name)))
            }
        }
        return byID.map { Leftover(bundleID: $0.key, files: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.size > $1.size }
    }

    /// "com.example.Foo.plist" → "com.example.Foo"; nil for names that aren't bundle IDs.
    nonisolated static func bundleID(inName name: String) -> String? {
        var stem = name
        for ext in [".plist", ".savedState", ".binarycookies"] where stem.hasSuffix(ext) {
            stem = String(stem.dropLast(ext.count))
        }
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              ["com", "org", "net", "io", "app", "dev", "co", "me", "de", "cn", "jp", "uk", "fr", "ru", "info", "us", "ai"]
                .contains(parts[0].lowercased()) else { return nil }
        if stem.hasPrefix("com.apple.") || notApps.contains(where: { stem.hasPrefix($0) }) { return nil }
        return stem
    }

    /// Tools and shared helpers that keep files by bundle ID without being an app.
    nonisolated static let notApps = ["org.swift.", "org.sparkle-project.", "com.microsoft.autoupdate", "org.llvm.",
                                      "com.github.", "org.python.", "com.docker.cli", "io.sentry", "org.homebrew."]

    /// Installed, or from a vendor with something installed (helpers and updaters belong to it).
    nonisolated static func isKnown(_ id: String, installed: Set<String>) -> Bool {
        let lower = id.lowercased()
        if installed.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { return true }
        let vendor = lower.split(separator: ".").prefix(2).joined(separator: ".")
        if installed.contains(where: { $0.hasPrefix(vendor + ".") }) { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }
}

// MARK: - Views

struct DuplicateAppsView: View {
    let model: LauncherModel
    private var inventory: AppInventory { .shared }

    var body: some View {
        CleanupPage(title: String(localized: "重复的 App"),
                    subtitle: inventory.duplicates.map { String(localized: "\($0.count) 个 App 装了不止一份。留下一份，其余可以在访达中拖到废纸篓") },
                    symbol: "square.on.square", tint: .teal,
                    empty: String(localized: "没有装了两份的 App")) {
            ForEach(inventory.duplicates ?? []) { app in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.copies[0].url.path))
                            .resizable().frame(width: 26, height: 26)
                        Text(app.name).font(.system(size: 13, weight: .semibold))
                        Text(app.bundleID).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    ForEach(app.copies) { copy in
                        CleanupFileLine(url: copy.url, detail: [copy.version.map { String(localized: "版本 \($0)") },
                                                                copy.modified.map { $0.formatted(date: .abbreviated, time: .omitted) }]
                                                                .compactMap { $0 }.joined(separator: " · "),
                                        size: copy.size, model: model)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

struct LeftoversView: View {
    let model: LauncherModel
    private var inventory: AppInventory { .shared }
    @State private var expanded: Set<String> = []

    var body: some View {
        let total = (inventory.leftovers ?? []).reduce(0) { $0 + $1.size }
        CleanupPage(title: String(localized: "残留文件"),
                    subtitle: inventory.leftovers.map { String(localized: "\($0.count) 个已卸载 App 的文件，共 \(Uninstaller.format(total))。LaunchUS 只列出，不会删除，确认没用后可以在访达中删掉") },
                    symbol: "archivebox", tint: .brown,
                    empty: String(localized: "没有找到已卸载 App 的残留文件")) {
            ForEach(inventory.leftovers ?? []) { leftover in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if expanded.contains(leftover.id) { expanded.remove(leftover.id) } else { expanded.insert(leftover.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded.contains(leftover.id) ? 90 : 0))
                            Text(verbatim: leftover.bundleID).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(leftover.files.count) 项").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Uninstaller.format(leftover.size)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(leftover.id) {
                        ForEach(leftover.files, id: \.url) { file in
                            CleanupFileLine(url: file.url, detail: file.url.deletingLastPathComponent().lastPathComponent,
                                            size: file.size, model: model)
                        }
                        .padding(.leading, 18)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

private struct CleanupPage<Content: View>: View {
    let title: String
    /// nil while scanning.
    let subtitle: String?
    let symbol: String
    let tint: Color
    let empty: String
    @ViewBuilder let content: () -> Content
    private var inventory: AppInventory { .shared }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 20, weight: .bold))
                    Spacer()
                    if inventory.cleaning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { inventory.scanCleanup(force: true) } label: {
                            Label(String(localized: "重新扫描"), systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                }
                Text(subtitle ?? String(localized: "正在扫描…"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
            Divider().padding(.horizontal, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) { content() }
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .overlay {
                if subtitle != nil, isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal").font(.system(size: 34, weight: .light)).foregroundStyle(tint.opacity(0.8))
                        Text(empty).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var isEmpty: Bool {
        title == String(localized: "重复的 App") ? (inventory.duplicates ?? []).isEmpty : (inventory.leftovers ?? []).isEmpty
    }
}

private struct CleanupFileLine: View {
    let url: URL
    let detail: String
    let size: Int64
    let model: LauncherModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            if !detail.isEmpty {
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Uninstaller.format(size)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Button {
                model.close()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "magnifyingglass.circle").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? .primary : .secondary)
            .help(String(localized: "在访达中显示"))
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}
