import AppKit
import SwiftUI

// Adding, resizing and removing widgets on the home grid.

extension LauncherModel {
    /// Widgets live on the home pages, not in search results or a category.
    var canAddWidget: Bool { !isSearching && categoryFilter == nil }

    func openWidgetGallery() {
        guard canAddWidget else { return }
        WidgetRegistry.shared.reload()
        isEditing = false
        sheet = .widgetGallery
    }

    /// Puts a new widget at the top of the page in view (or at a cell of a page, 0-based, from
    /// the AI tools; one past the last page starts a new page); the icons there move along.
    /// Sorted or scrolling, it always goes on the first page.
    @discardableResult
    func addWidget(_ kind: String, size: WidgetItem.Size, page: Int? = nil, cell: Int = 0) -> WidgetItem? {
        guard canAddWidget, let provider = WidgetRegistry.shared.provider(kind) else { return nil }
        if layout.isEmpty { layout = [[]] }
        let ordered = settings.sortOrder == .custom && settings.browseStyle == .paged
        var index = ordered ? min(currentPage, layout.count - 1) : 0
        if ordered, let page {
            index = min(max(0, page), layout.count)
            if index == layout.count { layout.append([]) }
        }
        let widget = WidgetItem(kind: kind, size: provider.fit(size))
        layout[index].insert(.widget(widget), at: min(max(0, cell), layout[index].count))
        if kind == BuiltInWidget.calendar.rawValue { WidgetEvents.shared.requestAccess() }
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) { commitLayout() }
        return widget
    }

    func resizeWidget(_ id: String, to size: WidgetItem.Size) {
        guard let pos = location(of: "widget:" + id), case .widget(var widget) = layout[pos.page][pos.slot] else { return }
        let wasFull = LayoutOps.fullPages(layout, columns: columns, rows: rows)
        widget.size = size
        layout[pos.page][pos.slot] = .widget(widget)
        refillIfLinedUp(wasFull)
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) { commitLayout() }
    }

    func removeWidget(_ id: String) {
        guard let pos = location(of: "widget:" + id) else { return }
        if editingNoteID == id { editingNoteID = nil }
        WidgetStore.shared.forget(id)
        // Placed freely, its cells simply empty out; lined up, the icons after it close the gap
        // and the page takes back what it pushed on to the next one.
        let wasFull = LayoutOps.fullPages(layout, columns: columns, rows: rows)
        layout[pos.page][pos.slot] = freePlacement ? .gap : .cover("")
        refillIfLinedUp(wasFull)
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) { commitLayout() }
    }

    /// Lined up, the apps a widget pushed on to the next page come back when it shrinks or
    /// goes (free placement keeps every icon where it is).
    private func refillIfLinedUp(_ wasFull: [Bool]) {
        guard !freePlacement else { return }
        layout = LayoutOps.refill(layout, wasFull: wasFull, columns: columns, rows: rows)
    }

    /// A click on a widget, at a point on its card (nil from the keyboard): the tools act on
    /// the spot clicked, the rest open what they come from.
    func activateWidget(_ widget: WidgetItem, at point: CGPoint?, card: CGSize) {
        guard !isEditing else { return }
        switch BuiltInWidget(rawValue: widget.kind) {
        case .note?:
            // Straight swap, no fade: the text stays where it was and the caret appears.
            editingNoteID = widget.id
        case .todo?:
            switch point.flatMap({ TodoWidget.hit($0, id: widget.id, size: widget.size, card: card) }) ?? .add {
            case .add: editingNoteID = widget.id
            case .item(let item): withAnimation(.easeInOut(duration: 0.2)) { WidgetStore.shared.toggleTodo(item, widget.id) }
            }
        case .clipboard?:
            if let point, let text = ClipboardWidget.item(at: point, id: widget.id, size: widget.size, card: card) {
                ClipboardHistory.shared.copy(text)
            }
        case .timer?:
            let hit = point.flatMap { TimerWidget.hit($0, size: widget.size, card: card) } ?? .toggle
            withAnimation(.easeInOut(duration: 0.2)) {
                switch hit {
                case .toggle: WidgetStore.shared.toggleTimer(widget.id)
                case .preset(let minutes): WidgetStore.shared.startTimer(widget.id, minutes: minutes)
                }
            }
        case .apps?:
            if let point, let app = AppsWidget.app(at: point, size: widget.size, card: card) { launch(app) }
        case .actions?:
            guard let point, let action = ActionsWidget.action(at: point, size: widget.size, card: card) else { return }
            if action.closesLauncher { onClose?() }
            // Let the launcher get out of the way before the screen locks or goes dark.
            DispatchQueue.main.asyncAfter(deadline: .now() + (action.closesLauncher ? 0.35 : 0)) {
                QuickActions.shared.perform(action)
            }
        default:
            openWidgetApp(widget)
        }
    }

    func endNoteEditing() {
        guard editingNoteID != nil else { return }
        editingNoteID = nil
    }

    /// Clicking a widget opens what it comes from; a missing plugin's widget opens the gallery.
    func openWidgetApp(_ widget: WidgetItem) {
        guard let provider = WidgetRegistry.shared.provider(widget.kind) else {
            openWidgetGallery()
            return
        }
        guard let target = provider.openTarget else { return }
        onClose?()
        if target.url.isFileURL {
            NSWorkspace.shared.openApplication(at: target.url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(target.url)
        }
    }
}
