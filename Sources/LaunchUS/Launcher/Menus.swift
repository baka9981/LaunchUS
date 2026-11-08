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
        // First and on its own: always there, so a second layout is easy to start.
        menu.addSubmenu(String(localized: "布局方案"), symbol: "rectangle.stack") { sub in
            addProfiles(to: sub, model: model)
        }
        menu.addSeparator()
        if includeSearchItems, !model.menuItems.isEmpty {
            for item in model.menuItems { menu.add(item.title, item.action) }
            menu.addSeparator()
        }
        if AIClient.isConfigured, model.chat == nil {
            menu.add(String(localized: "AI 聊天"), symbol: "sparkles") { model.openChat() }
            menu.addSeparator()
        }
        menu.addSubmenu(String(localized: "新建"), symbol: "plus") { sub in
            sub.add(String(localized: "智能文件夹…"), symbol: "folder.badge.gearshape") {
                let tags = model.completeQueryTags
                model.sheet = .editSmartFolder(nil, query: tags.isEmpty ? "" : model.query.trimmingCharacters(in: .whitespaces))
            }
            sub.add(String(localized: "启动项…"), symbol: "plus.app") { model.sheet = .editCustom(nil) }
            sub.add(String(localized: "小组件…"), symbol: "square.grid.2x2", enabled: model.canAddWidget) {
                model.openWidgetGallery()
            }
        }
        menu.addSubmenu(String(localized: "整理"), symbol: "square.grid.3x3.topleft.filled") { sub in
            let hasFolders = model.layout.joined().contains { if case .folder(let f) = $0 { !f.isSmart } else { false } }
            sub.add(String(localized: "解散所有文件夹"), symbol: "folder.badge.minus", enabled: hasFolders) {
                model.ungroupAllFolders()
            }
            // Sorted by name or date, positions come from the order.
            sub.add(String(localized: "文件夹移到最前"), symbol: "arrow.up.to.line", enabled: model.canRearrange) { model.moveAllFolders(toStart: true) }
            sub.add(String(localized: "文件夹移到最后"), symbol: "arrow.down.to.line", enabled: model.canRearrange) { model.moveAllFolders(toStart: false) }
            sub.addSeparator()
            sub.add(String(localized: "App 管理…"), symbol: "square.stack.3d.up") { model.sheet = .manager }
            sub.add(String(localized: "整理布局…")) { model.openSettings(.organize) }
        }
        // Only the view choices people switch back and forth; the rest is in settings.
        menu.addSubmenu(String(localized: "视图"), symbol: "eye") { sub in
            sub.addItem(.sectionHeader(title: String(localized: "排序方式")))
            for order in SortOrder.allCases {
                sub.add(order.title, checked: settings.sortOrder == order) { settings.sortOrder = order }
            }
            // The ring always turns pages; the browsing style is the grid's.
            guard settings.displayMode != .ring else { return }
            sub.addItem(.separator())
            sub.addItem(.sectionHeader(title: String(localized: "浏览样式")))
            for style in BrowseStyle.allCases {
                sub.add(style.title, checked: settings.browseStyle == style) { settings.browseStyle = style }
            }
            // The recent apps row is part of the scrolling grid only.
            if settings.pageStyle == .scroll {
                sub.addItem(.separator())
                sub.add(String(localized: "最近一行"), checked: settings.showFrequent) { settings.showFrequent.toggle() }
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
            addCategoryMenu(to: menu, ids: [app.id], model: model)
            menu.addSubmenu(String(localized: "移动到"), symbol: "arrow.right.square", enabled: model.canRearrange) { sub in
                let current = model.folderContaining(app.id)
                addMoveTargets(to: sub, model: model, current: current,
                               takeOut: folderID != nil && model.openFolder?.0.isSmart != true
                                   ? { model.takeOutOfFolder(app.id, folderID: folderID!) } : nil,
                               toFolder: { model.moveApp(app.id, toFolder: $0) },
                               toPage: { model.moveApp(app.id, toPage: $0) },
                               toEdge: { model.moveApps([app.id], toStart: $0) })
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
                    model.sheet = .editSmartFolder(folder.id, query: "")
                }
            } else {
                menu.add(String(localized: "解散文件夹"), symbol: "folder.badge.minus") { model.dissolveFolder(folder.id) }
            }
        case .widget(let widget):
            let provider = WidgetRegistry.shared.provider(widget.kind)
            if let provider, provider.sizes.count > 1 {
                menu.addSubmenu(String(localized: "大小"), symbol: "arrow.up.left.and.arrow.down.right") { sub in
                    for size in provider.sizes {
                        sub.add(size.title, checked: widget.size == size) { model.resizeWidget(widget.id, to: size) }
                    }
                }
            }
            if let target = provider?.openTarget {
                menu.add(target.title, symbol: "arrow.up.forward.app") { model.openWidgetApp(widget) }
            }
            switch BuiltInWidget(rawValue: widget.kind) {
            case .note?:
                let note = WidgetStore.shared.note(widget.id)
                menu.addSubmenu(String(localized: "颜色"), symbol: "paintpalette") { sub in
                    for color in NoteColor.allCases {
                        sub.add(color.title, checked: note.color == color) { WidgetStore.shared.setNoteColor(color, widget.id) }
                    }
                }
            case .todo?:
                let list = WidgetStore.shared.todoList(widget.id)
                menu.add(String(localized: "添加待办"), symbol: "plus.circle") {
                    model.activateWidget(widget, at: nil, card: .zero)
                }
                menu.add(String(localized: "清除已完成"), symbol: "checkmark.circle", enabled: list.contains(where: \.done)) {
                    WidgetStore.shared.clearDoneTodos(widget.id)
                }
            case .group?:
                let current = WidgetStore.shared.group(widget.id)
                menu.add(String(localized: "全部打开"), symbol: "square.stack.3d.forward.dottedline", enabled: current != nil) {
                    model.openGroupWidget(widget)
                }
                menu.addSubmenu(String(localized: "选择文件夹"), symbol: "folder") { sub in
                    let folders = model.groupFolders
                    if folders.isEmpty { sub.add(String(localized: "还没有文件夹"), enabled: false) {} }
                    for folder in folders {
                        sub.add(folder.name, checked: folder.id == current) { WidgetStore.shared.setGroup(folder.id, widget.id) }
                    }
                }
            case .photo?:
                let photo = WidgetStore.shared.photo(widget.id)
                menu.add(String(localized: "选择图片…"), symbol: "photo") { model.choosePhoto(for: widget.id) }
                menu.add(String(localized: "调整…"), symbol: "slider.horizontal.3", enabled: photo.file != nil) {
                    model.sheet = .photoWidget(widget.id)
                }
            case .clipboard?:
                menu.add(String(localized: "清空记录"), symbol: "trash", enabled: !ClipboardHistory.shared.items.isEmpty) {
                    ClipboardHistory.shared.clear()
                }
            case .timer?:
                let timer = WidgetStore.shared.timer(widget.id)
                menu.addSubmenu(String(localized: "时长"), symbol: "timer") { sub in
                    for minutes in [1, 5, 10, 15, 25, 30, 45, 60, 90] {
                        sub.add(String(localized: "\(minutes) 分钟"), checked: timer.minutes == minutes) {
                            WidgetStore.shared.startTimer(widget.id, minutes: minutes)
                        }
                    }
                }
                menu.add(String(localized: "重置"), symbol: "arrow.counterclockwise", enabled: timer.isRunning || timer.left != nil) {
                    WidgetStore.shared.resetTimer(widget.id)
                }
            default: break
            }
            menu.add(String(localized: "添加小组件…"), symbol: "square.grid.2x2", enabled: model.canAddWidget) {
                model.openWidgetGallery()
            }
            menu.addSeparator()
            menu.add(String(localized: "移除小组件"), symbol: "minus.circle") { model.removeWidget(widget.id) }
        case .gap: break
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
                menu.add(String(localized: "固定在最近一行"), symbol: "pin") { model.setPinnedToFrequent(true, app.id) }
            }
            menu.add(String(localized: "从常用中移除"), symbol: "minus.circle") { model.removeFromFrequent(app.id) }
            menu.addSeparator()
        }
        menu.add(String(localized: "清空常用记录"), symbol: "clock.arrow.circlepath") { model.resetFrequent() }
        menu.add(String(localized: "关闭最近一行"), symbol: "eye.slash") { model.settings.showFrequent = false }
        return menu
    }

    /// Right-click on one of several selected apps and folders. What only apps can do (open,
    /// tags, hide) acts on the picked apps and shows only when there are some.
    static func selection(_ model: LauncherModel) -> NSMenu {
        let menu = NSMenu.launcher()
        let ids = model.multiSelectedIDs
        menu.addItem(.sectionHeader(title: String(localized: "已选中 \(model.multiSelectedItems.count) 个项目")))
        if !ids.isEmpty {
            menu.add(String(localized: "打开"), symbol: "arrow.up.forward.app") { model.launchSelection() }
        }
        menu.add(String(localized: "创建新文件夹"), symbol: "folder.badge.plus") { model.folderFromSelection() }
        menu.addSubmenu(String(localized: "移动到"), symbol: "arrow.right.square", enabled: model.canRearrange) { sub in
            let inFolder = ids.contains { model.folderContaining($0) != nil }
            addMoveTargets(to: sub, model: model, current: nil,
                           takeOut: inFolder ? { model.takeSelectionOutOfFolders() } : nil,
                           toFolder: { model.moveSelection(toFolder: $0) },
                           toPage: { model.moveSelection(toPage: $0) },
                           toEdge: { start in
                               let items = model.multiSelectedItems
                               model.multiSelection = []
                               model.moveItems(items, toStart: start)
                           })
        }
        if !ids.isEmpty {
            addCategoryMenu(to: menu, ids: ids, model: model)
            menu.addSubmenu(String(localized: "标签"), symbol: "tag") { sub in
                for tag in model.allTags {
                    sub.add(tag, checked: ids.allSatisfy { model.meta(for: $0).tags.contains(tag) }) {
                        model.addTag(tag, toSelection: ids)
                    }
                }
            }
            menu.add(String(localized: "隐藏"), symbol: "eye.slash") { model.hideSelection() }
        }
        menu.addSeparator()
        menu.add(String(localized: "取消选择"), symbol: "xmark.circle") { model.multiSelection = [] }
        return menu
    }

    /// "App Store 分类" submenu: which category "@…" smart-folder conditions put the apps in.
    /// Shown only once some smart folder picks apps that way.
    static func addCategoryMenu(to menu: NSMenu, ids: [String], model: LauncherModel) {
        guard model.usesCategoryConditions else { return }
        let apps = ids.compactMap(model.app)
        guard !apps.isEmpty else { return }
        menu.addSubmenu(String(localized: "App Store 分类"), symbol: "square.grid.3x1.below.line.grid.1x2") { sub in
            for group in AppCategoryName.Group.allCases {
                sub.add(group.title, checked: apps.allSatisfy { model.appGroup($0) == group }) {
                    model.setCategory(group, for: ids)
                }
            }
            sub.addSeparator()
            sub.add(String(localized: "使用 App 自带的分类"), checked: apps.allSatisfy { model.meta(for: $0.id).group == nil }) {
                model.setCategory(nil, for: ids)
            }
        }
    }

    /// Right-click on a tab in the smart bar: everything about it is in 编辑智能栏.
    static func categoryTab(_ key: String, title: String, model: LauncherModel) -> NSMenu {
        let menu = NSMenu.launcher()
        menu.add(String(localized: "编辑智能栏…"), symbol: "slider.horizontal.3") {
            model.sheet = .editSmartFolder(model.smartFolder(forTab: key)?.id, query: "")
        }
        return menu
    }

    /// A coloured dot for the folder colour menu.
    /// Saved layouts, with the current one checked.
    static func addProfiles(to sub: NSMenu, model: LauncherModel) {
        let current = model.currentProfile
        // Each profile is shown its own way, so switching is also how full screen and window swap.
        for name in model.profileNames {
            sub.add("\(LayoutProfiles.title(name)) · \(model.profileMode(name).title)", checked: name == current) { model.switchProfile(name) }
        }
        sub.addSeparator()
        sub.add(String(localized: "新建布局方案…"), symbol: "plus") { model.sheet = .newProfile }
        // Straight to its settings, without going through the list of profiles.
        sub.add(String(localized: "编辑当前方案…"), symbol: "slider.horizontal.3") { model.openSettings(.display) }
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
                                       toPage: @escaping (Int) -> Void, toEdge: @escaping (Bool) -> Void) {
        if let takeOut {
            sub.add(String(localized: "移出文件夹"), takeOut)
            sub.addSeparator()
        }
        for target in model.folderTargets where target.id != current {
            sub.add(target.name, symbol: "folder") { toFolder(target.id) }
        }
        sub.addSeparator()
        // Scrolling runs the pages together, so there are none to pick.
        if Settings.shared.pageStyle == .scroll {
            sub.add(String(localized: "移到最前"), symbol: "arrow.up.to.line") { toEdge(true) }
            sub.add(String(localized: "移到最后"), symbol: "arrow.down.to.line") { toEdge(false) }
            return
        }
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
        overlay(NativeContextMenu(make: { _ in make() }))
    }

    /// One menu catcher for a whole grid: `make` gets the click in this view's coordinates
    /// (top-left origin) and returns the menu for what's there, or nil to pass the click to
    /// whatever lies beneath. Cheaper than a catcher per icon: each is an AppKit view that
    /// moves on every frame while paging.
    func nativeContextMenu(at make: @escaping (CGPoint) -> NSMenu?) -> some View {
        overlay(NativeContextMenu(make: make))
    }
}

private struct NativeContextMenu: NSViewRepresentable {
    let make: (CGPoint) -> NSMenu?

    func makeNSView(context: Context) -> ContextMenuView { ContextMenuView() }
    func updateNSView(_ view: ContextMenuView, context: Context) { view.make = make }
}

final class ContextMenuView: NSView {
    var make: ((CGPoint) -> NSMenu?)?
    /// Built while hit-testing the click, shown when it arrives.
    private var pending: NSMenu?
    /// The click `pending` was built for. While a menu is open the click stays the current
    /// event, and AppKit keeps hit-testing; each answer is reused instead of building again.
    private var tested: (time: TimeInterval, point: NSPoint, hit: Bool)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let menuClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard menuClick, super.hitTest(point) != nil else { return nil }
        if let tested, tested.time == event.timestamp, tested.point == point { return tested.hit ? self : nil }
        pending = make?(convert(point, from: superview))
        tested = (event.timestamp, point, pending != nil)
        return pending == nil ? nil : self
    }

    override func rightMouseDown(with event: NSEvent) { show(event) }
    override func mouseDown(with event: NSEvent) { show(event) }

    private func show(_ event: NSEvent) {
        let menu = pending ?? make?(convert(event.locationInWindow, from: nil))
        pending = nil
        guard let menu else { return }
        // The icon the menu belongs to lifts while the menu is open (`MenuTarget`).
        MenuTarget.shared.id = menu.identifier?.rawValue
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        MenuTarget.shared.id = nil
    }
}

/// The cell whose right-click menu is open, so it can show where the menu came from.
@MainActor @Observable final class MenuTarget {
    static let shared = MenuTarget()
    var id: String?

    /// Marks `menu` as belonging to the cell with this ID.
    static func tag(_ menu: NSMenu, _ id: String) -> NSMenu {
        menu.identifier = NSUserInterfaceItemIdentifier(id)
        return menu
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
