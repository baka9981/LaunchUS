import AppKit
import SwiftUI

// Dragging icons between slots, pages and folders.

extension LauncherModel {
    // MARK: - Drag and drop

    var draggedID: String? { drag?.item.id }
    /// A drag just finished; the mouse-up must not also count as a click.
    var dragJustEnded: Bool { Date().timeIntervalSince(lastDragEnd) < 0.3 }

    func beginDrag(_ entry: GridEntry, inFolder folderID: String?, pointer: CGPoint, iconCenter: CGPoint) {
        guard drag == nil, !isSearching, canRearrange else { return }
        if let folderID, openFolder?.0.id == folderID, openFolder?.0.isSmart == true { return }
        let item: LayoutItem
        switch entry {
        case .app(let app): item = .app(app.id)
        case .folder(let folder, _): item = .folder(folder)
        }
        selection = nil
        dragLocation = pointer
        var session = DragSession(
            item: item,
            folderID: folderID,
            grabOffset: CGSize(width: pointer.x - iconCenter.x, height: pointer.y - iconCenter.y)
        )
        if case .app(let draggedApp) = item, multiSelection.contains(draggedApp), multiSelection.count > 1 {
            // Lift the rest of the selection out so the whole group travels under the pointer.
            session.companions = multiSelectedIDs.filter { $0 != draggedApp }
            for id in session.companions { detach(id) }
            if let folderID, folderContaining(draggedApp) != folderID {
                // Lifting the others emptied the folder down to this app.
                session.folderID = nil
                dropFolder()
            }
        }
        drag = session
        if !session.companions.isEmpty {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { refresh() }
        }
    }

    func dragMoved(to point: CGPoint) {
        guard let session = drag else { return }
        dragLocation = point

        if let folderID = session.folderID {
            if metrics.folderPanelRect.insetBy(dx: -8, dy: -8).contains(point) {
                hoverInFolder(folderID, at: point)
            } else {
                popOutOfFolder(folderID)
            }
            return
        }

        handleEdgePaging(at: point)
        hoverInGrid(at: point)
    }

    func endDrag() {
        guard let session = drag else { return }
        cancelTimers()
        lastDragEnd = Date()
        var newFolderID: String?

        // Other ⌘-selected apps travel with the dragged one (already lifted out in beginDrag).
        let companions = session.companions

        if let targetID = mergeTargetID, case .app(let draggedApp) = session.item,
           let target = location(of: targetID), let source = location(of: session.item.id) {
            switch layout[target.page][target.slot] {
            case .app(let targetApp):
                let byID = Dictionary(catalog.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let name = AppCategoryName.folderName(for: ([targetApp, draggedApp] + companions).map { byID[$0]?.category })
                let folder = Folder(name: name, apps: [targetApp, draggedApp] + companions)
                layout[target.page][target.slot] = .folder(folder)
                newFolderID = folder.id
            case .folder(var folder):
                folder.apps.append(draggedApp)
                folder.apps.append(contentsOf: companions)
                layout[target.page][target.slot] = .folder(folder)
            }
            layout[source.page].remove(at: source.slot)
        } else if !companions.isEmpty, let at = location(of: session.item.id) {
            layout[at.page].insert(contentsOf: companions.map(LayoutItem.app), at: at.slot + 1)
        } else if !companions.isEmpty, case .app(let draggedApp) = session.item,
                  let folderID = folderContaining(draggedApp), let loc = location(ofFolder: folderID),
                  case .folder(var folder) = layout[loc.page][loc.slot], let i = folder.apps.firstIndex(of: draggedApp) {
            // Dropped inside an open folder: the group lands there, after the dragged app.
            folder.apps.insert(contentsOf: companions, at: i + 1)
            layout[loc.page][loc.slot] = .folder(folder)
        } else if !companions.isEmpty {
            if layout.isEmpty { layout = [[]] }
            layout[min(currentPage, layout.count - 1)].append(contentsOf: companions.map(LayoutItem.app))
        }
        if !companions.isEmpty || mergeTargetID != nil { multiSelection = [] }

        withAnimation(.easeOut(duration: 0.2)) {
            drag = nil
            mergeTargetID = nil
            commitLayout()
        }
        if let id = newFolderID { openFolder(id) }
    }

    private func cancelTimers() {
        pendingMove?.work.cancel()
        pendingMove = nil
        edgeWork?.cancel()
        edgeWork = nil
    }

    /// Runs `action` once the pointer has rested on the same target for a moment,
    /// so icons don't shuffle while the pointer merely passes over them.
    private func schedule(_ key: String, delay: Double = 0.18, _ action: @escaping () -> Void) {
        if pendingMove?.key == key { return }
        pendingMove?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingMove = nil
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { action() }
        }
        pendingMove = (key, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hoverInGrid(at point: CGPoint) {
        guard let session = drag else { return }
        let m = metrics
        let col = Int(floor((point.x - m.gridOriginX) / m.cellSize.width))
        let row = Int(floor((point.y - m.gridTop) / m.cellSize.height))
        guard (0..<columns).contains(col), (0..<rows).contains(row) else {
            // Outside the grid: no folder target and no pending shuffle.
            pendingMove?.work.cancel()
            pendingMove = nil
            if mergeTargetID != nil { withAnimation(.easeOut(duration: 0.15)) { mergeTargetID = nil } }
            return
        }

        while layout.count <= currentPage { layout.append([]) }
        let page = layout[currentPage]
        let slot = row * columns + col
        let center = m.iconCenter(slot: slot)
        let nearCenter = hypot(point.x - center.x, point.y - center.y) < m.iconSize * 0.32

        if slot < page.count, page[slot].id != session.item.id, nearCenter, case .app = session.item,
           !Self.isSmartFolder(page[slot]) {
            // Dropping an app onto another app or a folder makes / fills a folder.
            pendingMove?.work.cancel()
            pendingMove = nil
            if mergeTargetID != page[slot].id {
                withAnimation(.easeOut(duration: 0.15)) { mergeTargetID = page[slot].id }
            }
            return
        }
        if mergeTargetID != nil { withAnimation(.easeOut(duration: 0.15)) { mergeTargetID = nil } }

        let targetPage = currentPage
        let targetSlot = min(slot, page.count)
        schedule("grid:\(targetPage):\(targetSlot)") { [weak self] in
            self?.moveDragged(toPage: targetPage, slot: targetSlot)
        }
    }

    private func moveDragged(toPage page: Int, slot: Int) {
        guard let session = drag, let from = location(of: session.item.id), layout.indices.contains(page) else { return }
        if from.page == page && from.slot == min(slot, layout[page].count - 1) { return }
        let item = layout[from.page].remove(at: from.slot)
        layout[page].insert(item, at: min(slot, layout[page].count))
        // Push overflow forward but keep empty pages until the drop, so page numbers stay put.
        var i = 0
        while i < layout.count {
            if layout[i].count > perPage {
                let overflow = layout[i].removeLast()
                if i + 1 < layout.count { layout[i + 1].insert(overflow, at: 0) } else { layout.append([overflow]) }
            }
            i += 1
        }
        refresh()
    }

    private func handleEdgePaging(at point: CGPoint) {
        let edge: CGFloat = 36
        let direction = point.x < edge ? -1 : point.x > screenSize.width - edge ? 1 : 0
        guard direction != 0 else {
            edgeWork?.cancel()
            edgeWork = nil
            return
        }
        guard edgeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drag != nil else { return }
            self.edgeWork = nil
            let target = self.currentPage + direction
            guard target >= 0 else { return }
            if target >= self.layout.count {
                // Dragging past the last page opens a fresh one, unless the icon is already alone there.
                guard let last = self.layout.last,
                      last.count > 1 || !last.contains(where: { $0.id == self.draggedID }) else { return }
                self.layout.append([])
                self.refresh()
            }
            self.goToPage(target)
            self.dragMoved(to: self.dragLocation)
        }
        edgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func hoverInFolder(_ folderID: String, at point: CGPoint) {
        guard let session = drag, case .app(let appID) = session.item,
              let loc = location(ofFolder: folderID), case .folder(let folder) = layout[loc.page][loc.slot] else { return }
        let m = metrics
        let grid = m.folderGridRect
        let col = Int(floor((point.x - grid.minX) / m.cellSize.width))
        let row = Int(floor((point.y - grid.minY) / m.cellSize.height))
        guard (0..<folderColumns).contains(col), (0..<m.folderVisibleRows).contains(row) else {
            pendingMove?.work.cancel()
            pendingMove = nil
            return
        }
        let slot = folderScrolls
            ? min(Int(floor((point.y - grid.minY + folderScrollOffset) / m.cellSize.height)) * folderColumns + col,
                  folder.apps.count - 1)
            : min(folderPage * folderPerPage + row * folderColumns + col, folder.apps.count - 1)
        guard folder.apps.firstIndex(of: appID) != slot else {
            pendingMove?.work.cancel()
            pendingMove = nil
            return
        }
        schedule("folder:\(slot)") { [weak self] in
            guard let self, let loc = self.location(ofFolder: folderID),
                  case .folder(var f) = self.layout[loc.page][loc.slot],
                  let from = f.apps.firstIndex(of: appID) else { return }
            f.apps.remove(at: from)
            f.apps.insert(appID, at: min(slot, f.apps.count))
            self.layout[loc.page][loc.slot] = .folder(f)
            self.refresh()
        }
    }

    /// Dragging an app out of the open folder moves it onto the home grid.
    private func popOutOfFolder(_ folderID: String) {
        guard var session = drag, case .app(let appID) = session.item,
              let loc = location(ofFolder: folderID), case .folder(var folder) = layout[loc.page][loc.slot] else { return }
        cancelTimers()
        folder.apps.removeAll { $0 == appID }
        // A folder with a single app left dissolves into that app, like Launchpad.
        layout[loc.page][loc.slot] = folder.apps.count == 1 ? .app(folder.apps[0]) : .folder(folder)
        while layout.count <= currentPage { layout.append([]) }
        layout[currentPage].append(.app(appID))
        session.folderID = nil
        drag = session
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
            dropFolder()
            refresh()
        }
        moveDragged(toPage: currentPage, slot: layout[currentPage].count - 1)
    }

    private static func isSmartFolder(_ item: LayoutItem) -> Bool {
        if case .folder(let f) = item { return f.isSmart }
        return false
    }
}
