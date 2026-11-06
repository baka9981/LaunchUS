import AppKit
import Observation
import SwiftUI

/// A file or folder Spotlight found for the search field.
struct FoundFile: Identifiable, Equatable {
    let url: URL
    let name: String
    let isFolder: Bool
    let used: Date?
    var id: String { url.path }
}

/// Spotlight search for files and folders in the home folder, by name, most recently used first.
@MainActor @Observable
final class FileSearch {
    static let shared = FileSearch()
    static let limit = 5

    private(set) var results: [FoundFile] = []
    private(set) var text = ""
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func search(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text != self.text else { return }
        stop()
        self.text = text
        results = []
        guard text.count >= 2 else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@ AND NOT (%K == %@)",
                                      NSMetadataItemDisplayNameKey, text,
                                      NSMetadataItemContentTypeKey, "com.apple.application-bundle")
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let query = note.object as? NSMetadataQuery { self?.gathered(query, for: text) }
            }
        }
        self.query = query
        query.start()
    }

    func stop() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        text = ""
        results = []
    }

    private func gathered(_ query: NSMetadataQuery, for text: String) {
        guard query === self.query else { return }
        query.disableUpdates()
        var found: [FoundFile] = []
        for index in 0..<min(query.resultCount, 200) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  Self.isShown(path) else { continue }
            let type = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            found.append(FoundFile(url: URL(fileURLWithPath: path),
                                   name: (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? (path as NSString).lastPathComponent,
                                   isFolder: type == "public.folder",
                                   used: item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date))
            if found.count == Self.limit { break }
        }
        query.stop()
        results = found
    }

    /// Leaves out the Library, hidden folders and the insides of packages.
    nonisolated static func isShown(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let relative = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
        if relative.hasPrefix("/Library/") || relative.contains("/.") { return false }
        let parts = relative.split(separator: "/").dropLast()
        return !parts.contains { part in
            ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "xcodeproj", "xcworkspace", "pkg"]
                .contains((part as NSString).pathExtension.lowercased())
        } && !parts.contains("node_modules")
    }
}

/// The "文件" list under the search results.
struct FileResultsCard: View {
    let files: [FoundFile]
    let text: String
    let windowed: Bool
    let open: (FoundFile) -> Void
    let reveal: (FoundFile) -> Void
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("文件").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondary)
                Spacer()
                Button(action: showAll) {
                    Text("在访达中查看全部").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(secondary)
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(files) { file in
                FileRow(file: file, windowed: windowed, open: { open(file) }, reveal: { reveal(file) })
            }
        }
        .padding(10)
        .frame(width: SearchCard.width)
        .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private var secondary: AnyShapeStyle { windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.6)) }
}

private struct FileRow: View {
    let file: FoundFile
    let windowed: Bool
    let open: () -> Void
    let reveal: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: { NSEvent.modifierFlags.contains(.command) ? reveal() : open() }) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                    Text(verbatim: folderText).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.55)))
                }
                Spacer(minLength: 8)
                if let used = file.used {
                    Text(used, format: .relative(presentation: .named))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(windowed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white.opacity(0.45)))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(hover ? (windowed ? Color.primary.opacity(0.07) : Color.white.opacity(0.12)) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(String(localized: "按住 ⌘ 点按：在访达中显示"))
        .contextMenu {
            Button(String(localized: "打开"), action: open)
            Button(String(localized: "在访达中显示"), action: reveal)
            Button(String(localized: "拷贝路径")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
        }
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
    }

    private var folderText: String {
        (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
