import AppKit
import SwiftUI

// The launcher's menus are plain AppKit menus, built once when they open. SwiftUI menus are
// re-evaluated while open, which made moving through them stutter.

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true, checked: Bool = false,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true, checked: Bool = false,
             _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title, symbol: symbol, key: key, enabled: enabled, checked: checked, handler: handler)
        addItem(item)
        return item
    }

    @discardableResult
    func addSubmenu(_ title: String, symbol: String? = nil, enabled: Bool = true, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        build(sub)
        item.submenu = sub
        item.isEnabled = enabled && !sub.items.isEmpty
        addItem(item)
        return item
    }

    /// An item shown in place of the one before it while ⌥ is held.
    @discardableResult
    func addAlternate(_ title: String, symbol: String? = nil, key: String = "", _ handler: @escaping () -> Void) -> NSMenuItem {
        let base = items.last
        let item = ActionMenuItem(title, symbol: symbol, key: key, handler: handler)
        if let base, !base.keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = base.keyEquivalentModifierMask.union(.option)
        } else {
            // With no shortcut, the pair only differs by ⌥; NSMenuItem defaults the mask to ⌘.
            base?.keyEquivalentModifierMask = []
            item.keyEquivalentModifierMask = .option
        }
        item.isAlternate = true
        addItem(item)
        return item
    }

    func addSeparator() {
        if let last = items.last, !last.isSeparatorItem { addItem(.separator()) }
    }

    static func launcher() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }
}

/// Builds the launcher's menus from the model's current state.
@MainActor
enum LauncherMenus {
    /// Right-click on empty space, and the "⋯" button (with the search field's extra items first).
    static func main(_ model: LauncherModel, includeSearchItems: Bool = false) -> NSMenu {
        let menu = NSMenu.launcher()
        let settings = Settings.shared
        if includeSearchItems, !model.menuItems.isEmpty {
            for item in model.menuItems { menu.add(item.title, item.action) }
            menu.addSeparator()
        }
        menu.addSubmenu(String(localized: "新建"), symbol: "plus") { sub in
            sub.add(String(localized: "启动项…"), symbol: "plus.app") { model.sheet = .editCustom(nil) }
            sub.add(String(localized: "智能文件夹…"), symbol: "folder.badge.gearshape") {
                let tags = model.completeQueryTags
                model.sheet = .editSmartFolder(nil, query: tags.isEmpty ? "" : model.query.trimmingCharacters(in: .whitespaces))
            }
        }
        menu.addSubmenu(String(localized: "整理"), symbol: "square.grid.3x3.topleft.filled") { sub in
            let hasFolders = model.layout.joined().contains { if case .folder(let f) = $0 { !f.isSmart } else { false } }
            sub.add(String(localized: "解散所有文件夹"), symbol: "folder.badge.minus", enabled: hasFolders) {
                model.ungroupAllFolders()
            }
            sub.add(String(localized: "文件夹移到最前"), symbol: "arrow.up.to.line") { model.moveAllFolders(toStart: true) }
            sub.add(String(localized: "文件夹移到最后"), symbol: "arrow.down.to.line") { model.moveAllFolders(toStart: false) }
            sub.addSeparator()
            sub.add(String(localized: "App 管理…"), symbol: "square.stack.3d.up") { model.sheet = .manager }
            sub.add(String(localized: "整理布局…")) { model.openSettings(.organize) }
        }
        // Only the two view choices people switch back and forth; the rest is in settings.
        menu.addSubmenu(String(localized: "视图"), symbol: "eye") { sub in
            sub.addItem(.sectionHeader(title: String(localized: "排序方式")))
            for order in SortOrder.allCases {
                sub.add(order.title, checked: settings.sortOrder == order) { settings.sortOrder = order }
            }
            sub.addItem(.separator())
            sub.addItem(.sectionHeader(title: String(localized: "浏览样式")))
            for style in BrowseStyle.allCases {
                sub.add(style.title, checked: settings.browseStyle == style) { settings.browseStyle = style }
            }
        }
        if model.profileNames.count > 1 {
            menu.addSubmenu(String(localized: "布局方案"), symbol: "rectangle.stack") { sub in
                addProfiles(to: sub, model: model)
            }
        }
        if model.hiddenUnlocked {
            menu.addSeparator()
            menu.add(String(localized: "显示隐藏的 App"), symbol: "eye.slash") { model.revealHidden() }
            menu.add(String(localized: "锁定隐藏的 App"), symbol: "lock") { model.lockHidden() }
        }
        menu.addSeparator()
        menu.add(String(localized: "设置…"), symbol: "gearshape", key: ",") { model.openSettings() }
        menu.add(String(localized: "退出"), symbol: "power", key: "q") { NSApp.terminate(nil) }
        // Hold ⌥ to swap Quit for Restart.
        menu.addAlternate(String(localized: "重启"), symbol: "arrow.triangle.2.circlepath", key: "q") { AppRelauncher.relaunch() }
        return menu
    }

    /// Right-click on one app or folder.
    static func entry(_ entry: GridEntry, model: LauncherModel, folderID: String?) -> NSMenu {
        let menu = NSMenu.launcher()
        switch entry {
        case .app(let app) where SettingsPanes.isPane(app.id):
            menu.add(String(localized: "打开"), symbol: "arrow.up.forward.app") { model.launch(app) }
        case .app(let app):
            let meta = model.meta(for: app.id)
            menu.add(String(localized: "打开"), symbol: "arrow.up.forward.app") { model.launch(app) }
            if model.runningIDs.contains(app.id) {
                menu.add(String(localized: "退出"), symbol: "xmark.circle") { RunningApps.quit(app, force: false) }
                // Hold ⌥ for Force Quit, as in the Dock.
                menu.addAlternate(String(localized: "强制退出"), symbol: "xmark.octagon") { RunningApps.quit(app, force: true) }
            }
            if app.custom == nil || app.custom == .file {
                menu.add(String(localized: "在访达中显示"), symbol: "folder") { model.reveal(app.url.path) }
            }
            if app.custom == nil {
                // Hold ⌥, as in Finder.
                menu.addAlternate(String(localized: "显示简介"), symbol: "info.circle") {
                    model.onClose?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { FinderInfo.show(app.url) }
                }
                menu.add(String(localized: "简介…"), symbol: "info.circle") { model.showInfo(app.id) }
            }
            menu.addSeparator()
            // Name, icon, tags and Dock all live in one editor.
            menu.add(String(localized: "编辑…"), symbol: "pencil") {
                model.sheet = app.isCustom ? .editCustom(app.id) : .editApp(app.id)
            }
            menu.addSubmenu(String(localized: "移动到"), symbol: "arrow.right.square", enabled: model.canRearrange) { sub in
                let current = model.folderContaining(app.id)
                addMoveTargets(to: sub, model: model, current: current,
                               takeOut: folderID != nil && model.openFolder?.0.isSmart != true
                                   ? { model.takeOutOfFolder(app.id, folderID: folderID!) } : nil,
                               toFolder: { model.moveApp(app.id, toFolder: $0) },
                               toPage: { model.moveApp(app.id, toPage: $0) })
            }
            if meta.hidden {
                menu.add(String(localized: "取消隐藏"), symbol: "eye") { model.setHidden(false, for: app.id) }
            } else {
                menu.add(String(localized: "隐藏"), symbol: "eye.slash") { model.setHidden(true, for: app.id) }
            }
            menu.addSeparator()
            if app.isCustom {
                menu.add(String(localized: "删除启动项…"), symbol: "trash") { model.sheet = .confirmDeleteCustom(app.id) }
            } else {
                menu.add(String(localized: "卸载…"), symbol: "trash", enabled: app.isRemovable) { model.sheet = .confirmTrash(app.id) }
            }
        case .folder(let folder, let apps):
            menu.add(String(localized: "打开"), symbol: "folder") { model.openFolder(folder.id) }
            menu.add(String(localized: "全部打开"), symbol: "square.stack.3d.forward.dottedline", enabled: !apps.isEmpty) {
                model.openAll(folder.id)
            }
            menu.add(String(localized: "快捷键…"), symbol: "command") { model.sheet = .folderShortcut(folder.id) }
            menu.add(String(localized: "重命名"), symbol: "pencil") { model.startRenaming(folder: folder.id) }
            menu.addSubmenu(String(localized: "颜色"), symbol: "paintpalette") { sub in
                sub.add(String(localized: "无"), checked: folder.color == nil) { model.setFolderColor(folder.id, nil) }
                sub.addSeparator()
                for color in FolderColor.allCases {
                    let item = sub.add(color.title, checked: folder.color == color.rawValue) { model.setFolderColor(folder.id, color) }
                    item.image = Self.swatch(color)
                }
            }
            menu.addSeparator()
            if folder.isSmart {
                menu.add(String(localized: "编辑智能文件夹…"), symbol: "slider.horizontal.3") {
                    model.sheet = .editSmartFolder(folder.id, query: folder.query ?? "")
                }
                menu.add(String(localized: "删除智能文件夹"), symbol: "trash") { model.dissolveFolder(folder.id) }
            } else {
                menu.add(String(localized: "解散文件夹"), symbol: "folder.badge.minus") { model.dissolveFolder(folder.id) }
            }
        }
        return menu
    }

    /// Right-click on the frequently used row: on an app, or on the row's empty space.
    static func frequent(_ app: AppItem?, model: LauncherModel) -> NSMenu {
        let menu = NSMenu.launcher()
        if let app {
            menu.add(String(localized: "打开"), symbol: "arrow.up.forward.app") { model.launch(app) }
            if app.custom == nil || app.custom == .file {
                menu.add(String(localized: "在访达中显示"), symbol: "folder") { model.reveal(app.url.path) }
            }
            menu.addSeparator()
            if model.isPinnedToFrequent(app.id) {
                menu.add(String(localized: "取消固定"), symbol: "pin.slash") { model.setPinnedToFrequent(false, app.id) }
            } else {
                menu.add(String(localized: "固定在常用一行"), symbol: "pin") { model.setPinnedToFrequent(true, app.id) }
            }
            menu.add(String(localized: "从常用中移除"), symbol: "minus.circle") { model.removeFromFrequent(app.id) }
            menu.addSeparator()
        }
        menu.add(String(localized: "清空常用记录"), symbol: "clock.arrow.circlepath") { model.resetFrequent() }
        menu.add(String(localized: "隐藏常用一行"), symbol: "eye.slash") { model.settings.showFrequent = false }
        return menu
    }

    /// Right-click on one of several selected apps.
    static func selection(_ model: LauncherModel) -> NSMenu {
        let menu = NSMenu.launcher()
        let ids = model.multiSelectedIDs
        menu.addItem(.sectionHeader(title: String(localized: "已选中 \(ids.count) 个项目")))
        menu.add(String(localized: "打开"), symbol: "arrow.up.forward.app") { model.launchSelection() }
        menu.add(String(localized: "创建新文件夹"), symbol: "folder.badge.plus") { model.folderFromSelection() }
        menu.addSubmenu(String(localized: "移动到"), symbol: "arrow.right.square", enabled: model.canRearrange) { sub in
            let inFolder = ids.contains { model.folderContaining($0) != nil }
            addMoveTargets(to: sub, model: model, current: nil,
                           takeOut: inFolder ? { model.takeSelectionOutOfFolders() } : nil,
                           toFolder: { model.moveSelection(toFolder: $0) },
                           toPage: { model.moveSelection(toPage: $0) })
        }
        menu.addSubmenu(String(localized: "标签"), symbol: "tag") { sub in
            for tag in model.allTags {
                sub.add(tag, checked: ids.allSatisfy { model.meta(for: $0).tags.contains(tag) }) {
                    model.addTag(tag, toSelection: ids)
                }
            }
        }
        menu.add(String(localized: "隐藏"), symbol: "eye.slash") { model.hideSelection() }
        menu.addSeparator()
        menu.add(String(localized: "取消选择"), symbol: "xmark.circle") { model.multiSelection = [] }
        return menu
    }

    /// A coloured dot for the folder colour menu.
    /// Saved layouts, with the current one checked.
    static func addProfiles(to sub: NSMenu, model: LauncherModel) {
        let current = model.currentProfile
        for name in model.profileNames {
            sub.add(LayoutProfiles.title(name), checked: name == current) { model.switchProfile(name) }
        }
        sub.addSeparator()
        sub.add(String(localized: "新建布局方案…"), symbol: "plus") { model.sheet = .newProfile }
        sub.add(String(localized: "删除当前方案"), symbol: "trash", enabled: !current.isEmpty) { model.deleteProfile(current) }
    }

    private static func swatch(_ color: FolderColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color.color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }

    private static func addMoveTargets(to sub: NSMenu, model: LauncherModel, current: String?,
                                       takeOut: (() -> Void)?, toFolder: @escaping (String) -> Void,
                                       toPage: @escaping (Int) -> Void) {
        if let takeOut {
            sub.add(String(localized: "移出文件夹"), takeOut)
            sub.addSeparator()
        }
        for target in model.folderTargets where target.id != current {
            sub.add(target.name, symbol: "folder") { toFolder(target.id) }
        }
        sub.addSeparator()
        let pages = model.layout.filter { !$0.isEmpty }.count
        for page in 0..<pages {
            sub.add(String(localized: "第 \(page + 1) 页")) { toPage(page) }
        }
        sub.add(String(localized: "新的一页")) { toPage(pages) }
    }
}

// MARK: - Showing menus from SwiftUI

extension View {
    /// Shows an AppKit menu on right-click (or Control-click); other clicks pass through.
    func nativeContextMenu(_ make: @escaping () -> NSMenu?) -> some View {
        overlay(NativeContextMenu(make: make))
    }
}

private struct NativeContextMenu: NSViewRepresentable {
    let make: () -> NSMenu?

    func makeNSView(context: Context) -> ContextMenuView { ContextMenuView() }
    func updateNSView(_ view: ContextMenuView, context: Context) { view.make = make }
}

final class ContextMenuView: NSView {
    var make: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let menuClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return menuClick ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) { show(event) }
    override func mouseDown(with event: NSEvent) { show(event) }

    private func show(_ event: NSEvent) {
        guard let menu = make?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// The "⋯" button: a plain button that pops up an AppKit menu under itself.
struct MenuButton<Label: View>: View {
    let make: () -> NSMenu
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            // Below the pointer's button, like a pull-down.
            make().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: { label() }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "更多"))
    }
}
