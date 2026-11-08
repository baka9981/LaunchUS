import AppKit
import SwiftUI

// Dragging icons between slots, pages and folders.

extension LauncherModel {
    // MARK: - Drag and drop

    var draggedID: String? { drag?.item.id ?? landing?.item.id }
    /// A drag just finished; the mouse-up must not also count as a click.
    var dragJustEnded: Bool { Date().timeIntervalSince(lastDragEnd) < 0.3 }

    func beginDrag(_ entry: GridEntry, inFolder folderID: String?, pointer: CGPoint, iconCenter: CGPoint) {
        guard drag == nil, !isSearching, canRearrange else { return }
        if let folderID, openFolder?.0.id == folderID, openFolder?.0.isSmart == true { return }
        let item: LayoutItem
        switch entry {
        case .app(let app): item = .app(app.id)
        case .folder(let folder, _): item = .folder(folder)
        case .widget(let widget): item = .widget(widget)
        case .gap: return
        }
        selection = nil
        dragLocation = pointer
        // The scrolling grid's cells don't know how far it is scrolled; find the icon on screen.
        var iconCenter = folderID == nil && settings.browseStyle == .scroll
            ? scrollIconCenter(of: entry.id) ?? iconCenter : iconCenter
        if case .widget(let widget) = entry, folderID == nil, settings.browseStyle == .scroll,
           let first = scrollIconCenter(of: entry.id) {
            // That's its first cell; a widget is held by its card.
            let rect = metrics.widgetRect(first: first, span: widget.size.span(columns: columns, rows: rows))
            iconCenter = CGPoint(x: rect.midX, y: rect.midY)
        }
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

        // A widget goes by its top-left cell, under wherever its card is held.
        var probe = point
        if case .widget(let widget) = session.item {
            let center = CGPoint(x: point.x - session.grabOffset.width, y: point.y - session.grabOffset.height)
            probe = metrics.widgetFirstCell(center: center, span: widget.size.span(columns: columns, rows: rows))
        }
        if settings.browseStyle == .scroll {
            handleEdgeScrolling(at: point)
            hoverInScrollGrid(at: probe)
            return
        }
        handleEdgePaging(at: point)
        hoverInGrid(at: probe)
    }

    /// The scrolling grid: pages run together without their empty cells, so a cell there is
    /// the n-th icon of the layout, and moving one shifts the rest along.
    private func hoverInScrollGrid(at point: CGPoint) {
        guard let session = drag else { return }
        let m = metrics
        let top = m.gridTop + scrollLead - gridScrollOffset
        let col = Int(floor((point.x - m.gridOriginX) / m.cellSize.width))
        let row = Int(floor((point.y - top) / m.cellSize.height))
        let flat = layout.flatMap { $0.filter { !$0.isGap } }
        let cells = scrollCells
        guard (0..<columns).contains(col), row >= 0, point.y > m.gridTop, !flat.isEmpty else {
            pendingMove?.work.cancel()
            pendingMove = nil
            if mergeTargetID != nil { withAnimation(.easeOut(duration: 0.15)) { mergeTargetID = nil } }
            return
        }
        let index = row * columns + col
        let center = CGPoint(x: m.gridOriginX + (CGFloat(col) + 0.5) * m.cellSize.width,
                             y: top + (CGFloat(row) + 0.5) * m.cellSize.height)
        let nearCenter = hypot(point.x - center.x, point.y - center.y) < m.iconSize * 0.32
        // Cells are packed around widgets, so an item is found by its ID, not by counting.
        let here = index < cells.count && !cells[index].entry.isGap
            ? flat.firstIndex { $0.id == cells[index].entry.id } : nil
        if let here, flat[here].id != session.item.id, nearCenter, case .app = session.item,
           !flat[here].isWidget, !Self.isSmartFolder(flat[here]) {
            pendingMove?.work.cancel()
            pendingMove = nil
            if mergeTargetID != flat[here].id {
                withAnimation(.easeOut(duration: 0.15)) { mergeTargetID = flat[here].id }
            }
            return
        }
        if mergeTargetID != nil { withAnimation(.easeOut(duration: 0.15)) { mergeTargetID = nil } }
        // An empty cell goes by the next item after it, or the end.
        let next = here ?? cells.indices.dropFirst(min(index, cells.count)).lazy
            .filter { !cells[$0].entry.isGap }
            .compactMap { i in flat.firstIndex { $0.id == cells[i].entry.id } }.first
        let target = min(next ?? flat.count - 1, flat.count - 1)
        schedule("scroll:\(target)") { [weak self] in self?.moveDraggedInOrder(to: target) }
    }

    /// Moves the held item to the `index`-th place among all icons, keeping every page's
    /// cells (and empty cells) where they are: the icons just shift along them.
    private func moveDraggedInOrder(to index: Int) {
        guard let session = drag else { return }
        var flat = layout.flatMap { $0.filter { !$0.isGap } }
        guard let from = flat.firstIndex(where: { $0.id == session.item.id }), from != index,
              flat.indices.contains(index) else { return }
        flat.insert(flat.remove(at: from), at: index)
        var next = 0
        for p in layout.indices {
            for s in layout[p].indices where !layout[p][s].isGap {
                layout[p][s] = flat[next]
                next += 1
            }
        }
        refresh()
    }

    /// Holding an icon near the top or bottom of the scrolling grid scrolls it.
    private func handleEdgeScrolling(at point: CGPoint) {
        let m = metrics
        let edge = m.cellSize.height * 0.4
        let bottom = m.size.height * 0.97
        let direction: CGFloat = point.y < m.gridTop + edge && point.y > m.gridTop - edge * 2 ? -1
            : point.y > bottom - edge ? 1 : 0
        guard direction != 0 else {
            edgeScroll?.invalidate()
            edgeScroll = nil
            return
        }
        guard edgeScroll == nil else { return }
        edgeScroll = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.drag != nil else { timer.invalidate(); return }
                let rows = (self.scrollCells.count + self.columns - 1) / self.columns
                let content = self.scrollLead + CGFloat(rows) * m.cellSize.height + m.scrollTail
                let viewport = m.scrollViewport
                let y = min(max(0, self.gridScrollOffset + direction * 9), max(0, content - viewport))
                guard y != self.gridScrollOffset else { return }
                self.gridScrollRequest = y
                self.gridScrollOffset = y
                self.dragMoved(to: self.dragLocation)
            }
        }
    }

    func endDrag() {
        guard let session = drag else { return }
        cancelTimers()
        edgeScroll?.invalidate()
        edgeScroll = nil
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
            case .gap, .widget, .cover:
                break
            }
            vacate(page: source.page, slot: source.slot)
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

        let released = CGPoint(x: dragLocation.x - session.grabOffset.width, y: dragLocation.y - session.grabOffset.height)
        let mergedInto = mergeTargetID
        withAnimation(.easeOut(duration: 0.2)) {
            drag = nil
            mergeTargetID = nil
            commitLayout()
        }
        land(session.item, from: released, mergedInto: mergedInto)
        if let id = newFolderID { openFolder(id) }
    }

    /// Glides the let-go icon from the pointer into its slot (or into the folder it was dropped
    /// on) instead of it vanishing there and reappearing in the grid.
    private func land(_ item: LayoutItem, from: CGPoint, mergedInto: String?) {
        guard !settings.animationsOff, let target = landingTarget(for: item, mergedInto: mergedInto) else { return }
        landingToken += 1
        let token = landingToken
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { landing = DragLanding(item: item, position: from, scale: 1.08, opacity: 1) }
        // On the next turn: the icon must be drawn under the pointer first, or SwiftUI folds
        // both changes into one and it simply appears in its slot.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.landingToken == token else { return }
            withAnimation(self.settings.motion(.spring(response: 0.32, dampingFraction: 0.86), duration: 0.32)) {
                self.landing?.position = target
                self.landing?.scale = mergedInto == nil ? 1 : 0.5
                self.landing?.opacity = mergedInto == nil ? 1 : 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.animationSpeed.duration(0.4)) { [weak self] in
            guard let self, self.landingToken == token else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.landing = nil }
        }
    }

    /// Where the dropped icon ends up on screen, if that's on the page in view.
    private func landingTarget(for item: LayoutItem, mergedInto: String?) -> CGPoint? {
        let m = metrics
        if let folderID = openFolderID, case .app(let app) = item,
           let folder = openFolder, folder.0.id == folderID, let index = folder.1.firstIndex(where: { $0.id == app }) {
            if folderScrolls {
                let c = m.folderIconCenter(slot: index)
                return CGPoint(x: c.x, y: c.y - folderScrollOffset)
            }
            guard index / folderPerPage == folderPage else { return nil }
            return m.folderIconCenter(slot: index % folderPerPage)
        }
        guard openFolderID == nil, !isSearching else { return nil }
        let id = mergedInto ?? item.id
        if case .widget(let widget) = item {
            let span = widget.size.span(columns: columns, rows: rows)
            let first: CGPoint
            if settings.browseStyle == .scroll {
                guard let c = scrollIconCenter(of: id) else { return nil }
                first = c
            } else {
                guard let pos = location(of: id), pos.page == currentPage else { return nil }
                first = m.iconCenter(slot: pos.slot)
            }
            let rect = m.widgetRect(first: first, span: span)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        if settings.browseStyle == .scroll { return scrollIconCenter(of: id) }
        guard let pos = location(of: id), pos.page == currentPage else { return nil }
        return m.iconCenter(slot: pos.slot)
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

        if slot < page.count, !page[slot].isGap, page[slot].id != session.item.id, nearCenter, case .app = session.item,
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
        // Placed freely, any cell will do, even past the last icon; lined up, it's next in line.
        let targetSlot = freePlacement ? slot : min(slot, page.count)
        schedule("grid:\(targetPage):\(targetSlot)") { [weak self] in
            self?.moveDragged(toPage: targetPage, slot: targetSlot)
        }
    }

    private func moveDragged(toPage page: Int, slot: Int) {
        guard let session = drag, let from = location(of: session.item.id), layout.indices.contains(page) else { return }
        if freePlacement {
            moveDraggedFreely(from: from, toPage: page, slot: slot)
            return
        }
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

    /// Free placement: an empty cell simply takes the icon, leaving its old cell empty. An
    /// occupied one makes room by pushing the icons after it along up to the next empty cell.
    private func moveDraggedFreely(from: GridPos, toPage page: Int, slot: Int) {
        if from.page == page && from.slot == slot { return }
        let item = layout[from.page][from.slot]
        layout[from.page][from.slot] = .gap
        if slot < layout[page].count, !layout[page][slot].isGap {
            insertItems([item], page: page, slot: slot)
        } else {
            while layout[page].count <= slot { layout[page].append(.gap) }
            layout[page][slot] = item
        }
        // Too many on a page gives up its last empty cells, then pushes icons on;
        // empty pages stay until the drop, so page numbers hold still.
        for i in layout.indices {
            LayoutOps.trimTrailingGaps(&layout[i])
            while layout[i].count > perPage, let gap = layout[i].lastIndex(where: \.isGap) { layout[i].remove(at: gap) }
            if layout[i].count > perPage {
                let overflow = layout[i].removeLast()
                if i + 1 < layout.count { layout[i + 1].insert(overflow, at: 0) } else { layout.append([overflow]) }
            }
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
