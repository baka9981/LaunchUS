import AppKit
import ImageIO
import SwiftUI

// Two widgets of your own making: an app group (a folder's apps, opened all at once with a
// click) and a photo, toned with the same controls as the background.

// MARK: - App group

struct GroupWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize

    /// The folder this widget opens; the gallery's preview borrows the first one there is.
    @MainActor static func folder(_ id: String) -> Folder? {
        guard let model = WidgetHost.model else { return nil }
        if let folderID = WidgetStore.shared.group(id) { return model.folder(folderID) }
        return id.hasPrefix("preview-") ? model.firstGroupCandidate : nil
    }

    private var shape: (columns: Int, rows: Int) {
        switch size {
        case .small: (3, 2)
        case .medium: (6, 2)
        case .large: (4, 3)
        }
    }

    var body: some View {
        let folder = Self.folder(id)
        let apps = folder.flatMap { f in WidgetHost.model.map { $0.apps(in: f) } } ?? []
        VStack(alignment: .leading, spacing: unit * 0.08) {
            HStack(spacing: unit * 0.06) {
                Image(systemName: "square.stack.3d.forward.dottedline").font(.system(size: unit * 0.13, weight: .semibold))
                Text(folder?.name ?? String(localized: "App 组"))
                    .font(.system(size: unit * 0.14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if !apps.isEmpty {
                    Text("\(apps.count)").font(.system(size: unit * 0.11, weight: .medium).monospacedDigit()).opacity(0.6)
                }
            }
            if folder == nil {
                Spacer(minLength: 0)
                Text(String(localized: "右键选择一个文件夹，点一下就打开里面全部的 App"))
                    .font(.system(size: unit * 0.11, weight: .medium)).opacity(0.65)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                GeometryReader { geo in
                    let (c, r) = shape
                    let cells = ToolGrid.cells(count: min(apps.count, c * r), columns: c, rows: r, in: geo.size)
                    let icons = WidgetHost.model?.catalog.icons ?? [:]
                    let overflow = apps.count > c * r
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                            let side = min(cell.width, cell.height) * 0.86
                            Group {
                                if overflow && i == cells.count - 1 {
                                    Text("+\(apps.count - cells.count + 1)")
                                        .font(.system(size: side * 0.3, weight: .semibold).monospacedDigit())
                                        .frame(width: side * 0.8, height: side * 0.8)
                                        .background(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous).fill(.primary.opacity(0.12)))
                                } else if let icon = icons[apps[i].id] {
                                    Image(decorative: icon, scale: 2).resizable().interpolation(.high)
                                } else {
                                    RoundedRectangle(cornerRadius: side * 0.2, style: .continuous).fill(.primary.opacity(0.12))
                                        .padding(side * 0.1)
                                }
                            }
                            .frame(width: side, height: side)
                            .frame(width: cell.width, height: cell.height)
                            .offset(x: cell.minX, y: cell.minY)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension LauncherModel {
    /// What a new app group widget opens: the first ordinary folder with apps in it.
    var firstGroupCandidate: Folder? {
        for case .folder(let folder) in layout.joined() where !folder.isSmart && !folder.apps.isEmpty { return folder }
        return nil
    }

    /// Every folder a group widget could open, in grid order.
    var groupFolders: [Folder] {
        var seen = Set<String>()
        var all: [Folder] = []
        for case .folder(let folder) in layout.joined() where seen.insert(folder.id).inserted { all.append(folder) }
        for folder in barFolders where seen.insert(folder.id).inserted { all.append(folder) }
        return all
    }

    func openGroupWidget(_ widget: WidgetItem) {
        if let folder = GroupWidget.folder(widget.id), WidgetStore.shared.group(widget.id) != nil {
            openAll(folder.id)
        }
    }

    /// The photo widget: a click without a picture asks for one, with one it opens the adjustments.
    func openPhotoWidget(_ widget: WidgetItem) {
        if WidgetStore.shared.photo(widget.id).file == nil {
            choosePhoto(for: widget.id)
        } else {
            sheet = .photoWidget(widget.id)
        }
    }

    func choosePhoto(for id: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "选择一张图片放在小组件里")
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            var photo = WidgetStore.shared.photo(id)
            photo.file = try WidgetPhotos.importImage(url)
            WidgetStore.shared.setPhoto(photo, id)
        } catch {
            NSLog("LaunchUS: failed to copy widget photo: \(error)")
        }
    }

    func widget(_ id: String) -> WidgetItem? {
        for case .widget(let widget) in layout.joined() where widget.id == id { return widget }
        return nil
    }
}

// MARK: - Photo

extension WidgetStore {
    struct Photo: Codable, Equatable {
        /// The copy in `WidgetPhotos.directory`.
        var file: String?
        /// Sharp and untouched to start with; the same controls as the background.
        var style = BackgroundStyle(blur: 0, saturation: 1, dim: 0)
        /// Shows the whole picture instead of filling the card.
        var fit = false
    }
}

/// Pictures copied in for photo widgets, decoded small enough for a card.
@MainActor
enum WidgetPhotos {
    static var directory: URL { LayoutStore.directory.appendingPathComponent("WidgetPhotos", isDirectory: true) }
    private static var cache: [String: CGImage] = [:]

    static func importImage(_ source: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased())
        try fm.copyItem(at: source, to: directory.appendingPathComponent(name))
        return name
    }

    static func remove(_ name: String) {
        cache[name] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// At most 1200 pixels on the long side: plenty for a 4 × 4 card on a Retina screen.
    static func image(_ name: String) -> CGImage? {
        if let hit = cache[name] { return hit }
        let url = directory.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache[name] = image
        return image
    }
}

struct PhotoWidget: View {
    let id: String
    let unit: CGFloat
    let card: CGSize
    /// Set while adjusting, so the preview follows the sliders before they are saved.
    var override: WidgetStore.Photo?

    var body: some View {
        let photo = override ?? WidgetStore.shared.photo(id)
        if let file = photo.file, let image = WidgetPhotos.image(file) {
            PhotoLayer(image: image, photo: photo, card: card)
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.9), Color(red: 0.95, green: 0.6, blue: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.55)
                VStack(spacing: unit * 0.06) {
                    Image(systemName: "photo.badge.plus").font(.system(size: unit * 0.3))
                    if !id.hasPrefix("preview-") {
                        Text(String(localized: "点一下选择图片")).font(.system(size: unit * 0.11, weight: .medium))
                    }
                }
                .opacity(0.85)
            }
            .frame(width: card.width, height: card.height)
        }
    }
}

/// The picture with blur, colour, darkness and texture, like the launcher's background.
private struct PhotoLayer: View {
    let image: CGImage
    let photo: WidgetStore.Photo
    let card: CGSize

    var body: some View {
        let style = photo.style
        // The background's blur is in screen points; a card is a fraction of the screen.
        let blur = style.blur * Double(min(card.width, card.height)) / 900
        ZStack {
            if photo.fit {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: card.width, height: card.height).clipped()
                    .blur(radius: 18, opaque: true).opacity(0.6)
            }
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: photo.fit ? .fit : .fill)
                .frame(width: card.width, height: card.height)
                .clipped()
                .blur(radius: blur, opaque: !photo.fit)
                .saturation(style.saturation)
            BackgroundToning(style: style, blends: true)
            Color.black.opacity(style.dim)
        }
        .compositingGroup()
        .frame(width: card.width, height: card.height)
        .clipped()
    }
}

/// The photo widget's adjustments: a live preview, then the background's sliders.
struct PhotoWidgetCard: View {
    let model: LauncherModel
    let id: String
    @State private var photo = WidgetStore.Photo()
    @State private var loaded = false

    private var size: WidgetItem.Size { model.widget(id)?.size ?? .medium }

    var body: some View {
        let cells = size.cells
        // The preview fits a 260-point square, in the widget's own proportions.
        let box: CGFloat = 260
        let aspect = CGFloat(cells.width) / CGFloat(cells.height)
        let previewWidth = aspect >= 1 ? box : box * aspect
        let height = aspect >= 1 ? box / aspect : box
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "照片")).font(.system(size: 17, weight: .semibold))
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 16) {
                    PhotoWidget(id: id, unit: height / CGFloat(cells.height), card: CGSize(width: previewWidth, height: height), override: photo)
                        .clipShape(RoundedRectangle(cornerRadius: min(previewWidth, height) * 0.12, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                        .frame(width: box, height: height)
                    Button {
                        model.choosePhoto(for: id)
                        photo.file = WidgetStore.shared.photo(id).file
                    } label: {
                        Label(String(localized: "换一张…"), systemImage: "photo").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("风格").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                            ForEach(BackgroundStyle.presets.dropFirst()) { preset in
                                StyleChip(title: preset.title, selected: photo.style.matches(preset.style)) {
                                    withAnimation(.easeOut(duration: 0.2)) { photo.style = preset.style }
                                }
                            }
                        }
                    }
                    Toggle(String(localized: "完整显示图片，不裁切"), isOn: $photo.fit)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: box)

                VStack(alignment: .leading, spacing: 14) {
                    panel {
                        TunerGroup(title: String(localized: "模糊与颜色")) {
                            TunerSlider(title: String(localized: "模糊"),
                                        value: Binding(get: { (photo.style.blur / 240).squareRoot() },
                                                       set: { photo.style.blur = (240 * $0 * $0 * 10).rounded() / 10 }),
                                        range: 0...1, standard: 0, text: "\(Int(photo.style.blur.rounded()))")
                            TunerSlider(title: String(localized: "鲜艳度"), value: $photo.style.saturation,
                                        range: 0...2, standard: 1, text: percent(photo.style.saturation))
                            TunerSlider(title: String(localized: "色温"), value: $photo.style.temperature,
                                        range: -1...1, standard: 0, text: signed(photo.style.temperature)) {
                                LinearGradient(colors: [BackgroundToning.cool, .gray.opacity(0.3), BackgroundToning.warm],
                                               startPoint: .leading, endPoint: .trailing)
                            }
                            TunerSlider(title: String(localized: "着色"), value: $photo.style.tint,
                                        range: 0...1, standard: 0, text: percent(photo.style.tint))
                            // Only matters once there is some 着色.
                            if photo.style.tint > 0 {
                                TunerSlider(title: String(localized: "色调"), value: $photo.style.tintHue,
                                            range: 0...1, standard: 0.6, text: "\(Int((photo.style.tintHue * 360).rounded()))°") {
                                    LinearGradient(colors: stride(from: 0.0, through: 1, by: 1.0 / 12).map {
                                        Color(hue: $0, saturation: 0.7, brightness: 0.85)
                                    }, startPoint: .leading, endPoint: .trailing)
                                }
                            }
                        }
                    }
                    panel {
                        TunerGroup(title: String(localized: "明暗与质感")) {
                            TunerSlider(title: String(localized: "暗度"), value: $photo.style.dim,
                                        range: 0...0.6, standard: 0, text: percent(photo.style.dim / 0.6))
                            TunerSlider(title: String(localized: "暗角"), value: $photo.style.vignette,
                                        range: 0...1, standard: 0, text: percent(photo.style.vignette))
                            TunerSlider(title: String(localized: "颗粒感"), value: $photo.style.grain,
                                        range: 0...1, standard: 0, text: percent(photo.style.grain))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                Button(String(localized: "全部还原")) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        photo.style = WidgetStore.Photo().style
                        photo.fit = false
                    }
                }
                .disabled(photo.style.matches(WidgetStore.Photo().style) && !photo.fit)
                Spacer()
                Button(String(localized: "取消")) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "完成")) {
                    WidgetStore.shared.setPhoto(photo, id)
                    model.sheet = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            photo = WidgetStore.shared.photo(id)
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func signed(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

/// One of the photo editor's ready-made looks.
private struct StyleChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : .primary)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
