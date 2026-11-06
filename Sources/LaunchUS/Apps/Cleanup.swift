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

    /// The copy worth keeping: the newest version, then one in an Applications folder, then the latest built.
    var keeper: Copy? {
        copies.max { a, b in
            let order = UpdateChecker.compare(a.version ?? "0", b.version ?? "0")
            if order != .orderedSame { return order == .orderedAscending }
            let aApps = DuplicateApp.inApplications(a.url.path), bApps = DuplicateApp.inApplications(b.url.path)
            if aApps != bApps { return !aApps }
            return (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
        }
    }

    nonisolated static func inApplications(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
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

    /// Where apps keep their files under ~/Library, by bundle ID: the same places the uninstaller looks.
    nonisolated static let places = ["Application Support", "Caches", "Preferences", "Preferences/ByHost",
                                     "Saved Application State", "HTTPStorages", "WebKit", "Logs", "Cookies",
                                     "Containers", "Group Containers", "Application Scripts", "LaunchAgents"]

    nonisolated static func leftovers(installed: Set<String>) -> [Leftover] {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        var byID: [String: [Uninstaller.File]] = [:]
        for place in places {
            let folder = library.appendingPathComponent(place)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names {
                guard let id = bundleID(inName: name), !isKnown(id, installed: installed) else { continue }
                let url = folder.appendingPathComponent(name)
                if isShared(name, place: place, at: url, installed: installed) { continue }
                byID[id, default: []].append(Uninstaller.file(url))
            }
        }
        return byID.map { Leftover(bundleID: $0.key, files: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.size > $1.size }
    }

    /// Shared folders ("group.…", "<TEAMID>.…") are named after the developer, not the app, so the name says
    /// nothing about whether their app is gone. A group container records the app that made it; trust that,
    /// and leave every other shared folder alone.
    nonisolated static func isShared(_ name: String, place: String, at url: URL, installed: Set<String>) -> Bool {
        let first = name.split(separator: ".").first.map(String.init) ?? ""
        guard first == "group" || (first.count == 10 && first.allSatisfy { $0.isUppercase || $0.isNumber }) else { return false }
        guard place == "Group Containers",
              let meta = NSDictionary(contentsOf: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")),
              let creator = meta["MCMMetadataCreator"] as? String else { return true }
        return isKnown(creator, installed: installed)
    }

    /// "com.example.Foo.plist" → "com.example.Foo"; nil for names that aren't bundle IDs.
    nonisolated static func bundleID(inName name: String) -> String? {
        var stem = name
        for ext in [".plist", ".savedState", ".binarycookies"] where stem.hasSuffix(ext) {
            stem = String(stem.dropLast(ext.count))
        }
        var parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        // "group.<id>" and "<TEAMID>.<id>" (group containers, app scripts); "<id>.<UUID>" (ByHost).
        if let first = parts.first, first == "group" || (first.count == 10 && first.allSatisfy { $0.isUppercase || $0.isNumber }) {
            parts.removeFirst()
        }
        if let last = parts.last, last.count == 36, last.filter({ $0 == "-" }).count == 4 { parts.removeLast() }
        stem = parts.joined(separator: ".")
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
    @State private var confirmAll = false

    private var extras: [DuplicateApp.Copy] {
        (inventory.duplicates ?? []).flatMap { app in app.copies.filter { $0.id != app.keeper?.id } }
    }

    var body: some View {
        let extras = extras
        CleanupPage(title: String(localized: "重复的 App"),
                    subtitle: inventory.duplicates.map { String(localized: "\($0.count) 个 App 装了不止一份。每组标出了建议保留的一份（版本最新、在「应用程序」里）") },
                    symbol: "square.on.square", tint: .teal,
                    empty: String(localized: "没有装了两份的 App"), isEmpty: (inventory.duplicates ?? []).isEmpty) {
            ForEach(inventory.duplicates ?? []) { app in
                let keeper = app.keeper
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.copies[0].url.path))
                            .resizable().frame(width: 26, height: 26)
                        Text(app.name).font(.system(size: 13, weight: .semibold))
                        Text(app.bundleID).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Button(String(localized: "只保留建议的一份")) {
                            Task { await trash(app.copies.filter { $0.id != keeper?.id }.map(\.url)) }
                        }
                        .controlSize(.small)
                    }
                    ForEach(app.copies) { copy in
                        CleanupFileLine(url: copy.url,
                                        detail: [copy.version.map { String(localized: "版本 \($0)") },
                                                 copy.modified.map { $0.formatted(date: .abbreviated, time: .omitted) }]
                                            .compactMap { $0 }.joined(separator: " · "),
                                        size: copy.size, model: model,
                                        badge: copy.id == keeper?.id ? String(localized: "建议保留") : nil,
                                        trash: { Task { await trash([copy.url]) } })
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } footer: {
            if !extras.isEmpty {
                CleanupFooter(text: String(localized: "多余的 \(extras.count) 份，共 \(Uninstaller.format(extras.reduce(0) { $0 + $1.size }))"),
                              button: String(localized: "全部只保留建议的一份")) { confirmAll = true }
            }
        }
        .confirmationDialog(String(localized: "把 \(extras.count) 份多余的 App 移到废纸篓？"), isPresented: $confirmAll) {
            Button(String(localized: "移到废纸篓"), role: .destructive) { Task { await trash(extras.map(\.url)) } }
        } message: {
            Text("可以在废纸篓里找回")
        }
    }

    private func trash(_ urls: [URL]) async {
        let failed = await inventory.trash(urls)
        model.showNotice(failed == 0 ? String(localized: "已移到废纸篓")
                         : String(localized: "有 \(failed) 项无法移动，可能需要管理员权限"))
    }
}

struct LeftoversView: View {
    let model: LauncherModel
    private var inventory: AppInventory { .shared }
    @State private var expanded: Set<String> = []
    /// Ticked bundle IDs. Nothing is ticked at first: each one is a choice.
    @State private var chosen: Set<String> = []
    @State private var confirm = false

    private var selected: [Leftover] { (inventory.leftovers ?? []).filter { chosen.contains($0.id) } }

    var body: some View {
        let all = inventory.leftovers ?? []
        let selected = selected
        let total = all.reduce(0) { $0 + $1.size }
        CleanupPage(title: String(localized: "残留文件"),
                    subtitle: inventory.leftovers.map { String(localized: "\($0.count) 个已卸载 App 留在资源库里的文件，共 \(Uninstaller.format(total))") },
                    symbol: "archivebox", tint: .brown,
                    empty: String(localized: "没有找到已卸载 App 的残留文件"), isEmpty: all.isEmpty) {
            if !all.isEmpty {
                Toggle(isOn: Binding(get: { Set(all.map(\.id)).isSubset(of: chosen) }, set: { chosen = $0 ? Set(all.map(\.id)) : [] })) {
                    Text("全选").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 10)
            }
            ForEach(all) { leftover in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { chosen.contains(leftover.id) },
                                                 set: { if $0 { chosen.insert(leftover.id) } else { chosen.remove(leftover.id) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Button {
                            if expanded.contains(leftover.id) { expanded.remove(leftover.id) } else { expanded.insert(leftover.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(expanded.contains(leftover.id) ? 90 : 0))
                                Text(verbatim: leftover.bundleID).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text("\(leftover.files.count) 项").font(.system(size: 11)).foregroundStyle(.secondary)
                                if leftover.files.contains(where: \.restricted) {
                                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.orange)
                                        .help(String(localized: "部分文件受保护，移到废纸篓需要给 LaunchUS 完全磁盘访问权限"))
                                }
                                Spacer()
                                Text(Uninstaller.format(leftover.size)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if expanded.contains(leftover.id) {
                        ForEach(leftover.files, id: \.url) { file in
                            CleanupFileLine(url: file.url, detail: file.url.deletingLastPathComponent().lastPathComponent,
                                            size: file.size, model: model,
                                            trash: { Task { await trash([file.url]) } })
                        }
                        .padding(.leading, 40)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } footer: {
            if !all.isEmpty {
                CleanupFooter(text: String(localized: "已选 \(selected.count) 项，共 \(Uninstaller.format(selected.reduce(0) { $0 + $1.size }))"),
                              button: String(localized: "移到废纸篓"), disabled: selected.isEmpty) { confirm = true }
            }
        }
        .confirmationDialog(String(localized: "把 \(selected.count) 个已卸载 App 的残留文件移到废纸篓？"), isPresented: $confirm) {
            Button(String(localized: "移到废纸篓"), role: .destructive) {
                Task { await trash(selected.flatMap { $0.files.map(\.url) }) }
            }
        } message: {
            Text("可以在废纸篓里找回")
        }
    }

    private func trash(_ urls: [URL]) async {
        let failed = await inventory.trash(urls)
        model.showNotice(failed == 0 ? String(localized: "已移到废纸篓")
                         : String(localized: "有 \(failed) 项无法移动，给 LaunchUS 完全磁盘访问权限后再试"))
    }
}

private struct CleanupFooter: View {
    let text: String
    let button: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button(role: .destructive, action: action) {
                Label(button, systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(disabled || AppInventory.shared.cleaning)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
    }
}

private struct CleanupPage<Content: View, Footer: View>: View {
    let title: String
    /// nil while scanning.
    let subtitle: String?
    let symbol: String
    let tint: Color
    let empty: String
    let isEmpty: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
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
            Divider()
            footer()
        }
    }
}

private struct CleanupFileLine: View {
    let url: URL
    let detail: String
    let size: Int64
    let model: LauncherModel
    var badge: String? = nil
    var trash: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            if !detail.isEmpty {
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let badge {
                Text(badge).font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.12), in: Capsule())
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
            if let trash {
                Button(action: trash) {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? .red : .secondary)
                .help(String(localized: "移到废纸篓"))
            }
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}
