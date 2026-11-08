import SwiftUI
import AppKit

/// Grid geometry derived from the screen size, following the classic Launchpad layout:
/// icon centres every 12.5% of the width starting at
/// 12.5%, rows every 15.9% of the height starting at 17.7%, visible icon art 6% of the width.
struct GridMetrics: Equatable {
    let size: CGSize
    let columns: Int
    let rows: Int
    var folderColumns: Int { columns }
    /// The window's fixed row height can't stack every row in a folder panel with its title
    /// above it, so a windowed folder shows as many rows as fit (it pages or scrolls the rest).
    var folderRows: Int {
        guard windowed else { return rows }
        let half = min(size.height * 0.51 - folderTitleGap - 22, size.height * 0.49 - 34)
        return max(1, min(rows, Int((2 * half - 32) / cellSize.height)))
    }
    var folderTitleGap: CGFloat { windowed ? (folderHasQuery ? 46 : 28) : (size.height * 0.04).rounded() + (folderHasQuery ? 14 : 0) }
    /// Window mode: a compact glass panel styled after macOS's own Apps window.
    var windowed = false
    var paged = true
    /// Room for the recently-opened row between the search field and the grid.
    var frequentRow = false
    /// The category tabs take a row under the search field.
    var categoryBar = false

    var searchCenterY: CGFloat { windowed ? 28 : (size.height * 0.0615).rounded() }
    var searchSize: CGSize {
        windowed ? CGSize(width: size.width - 40, height: 44)
            : CGSize(width: max(240, size.width * 0.14).rounded(), height: max(32, size.height * 0.033).rounded())
    }
    /// Window mode: the line under the header, and the centre of the category tabs below it.
    var headerLineY: CGFloat { 56 }
    /// Full screen: halfway between the search field and the first row's artwork, so the gaps above and
    /// below the tabs match.
    var categoryBarY: CGFloat {
        windowed ? 80 : ((searchCenterY + searchSize.height / 2 + gridTop + cellSize.height / 2 - iconSize * 0.4) / 2).rounded()
    }
    /// Full screen: how far the category tabs push the grid down (its rows get shorter to make room).
    var fullScreenBarRoom: CGFloat { !windowed && categoryBar ? 36 : 0 }
    /// Vertical centre of the page dots.
    var dotsY: CGFloat { windowed ? size.height - 18 : size.height * 0.929 }
    var gridWidth: CGFloat { windowed ? size.width - 48 : size.width * 0.875 }
    var gridOriginX: CGFloat { (size.width - gridWidth) / 2 }
    /// Height of the recently-opened row (scrolling only): one grid row of named icons over a
    /// line, like the system Apps window. It sits at the top of the scrolling grid.
    /// As in the system Apps window: the row is one grid row plus a little room for the line,
    /// which goes that far under the names, so below it is the usual gap between rows.
    var frequentHeight: CGFloat { frequentRow ? cellSize.height + frequentLineSpace + 1 : 0 }
    /// Bottom of the names in the recent row (of the icons, with names hidden).
    var frequentLabelBottom: CGFloat {
        cellSize.height / 2 + (hideNames ? iconSize * 0.4 : iconSize / 2 + labelGap + labelSize * 1.2)
    }
    /// The usual gap from one row's names down to the next row's icons.
    var rowGap: CGFloat { cellSize.height - (frequentLabelBottom - (cellSize.height / 2 - iconSize * 0.4)) }
    /// Names to line: about three quarters of the row gap (15 pt in the window).
    var frequentLineSpace: CGFloat { max(8, (rowGap * 0.77).rounded()) }
    var frequentLineY: CGFloat { (frequentLabelBottom + frequentLineSpace).rounded() }
    var cellSize: CGSize {
        // Window mode scrolls in rows as tall as the system Apps window's; pages fit their rows.
        let height = windowed
            ? (paged ? ((size.height - gridTop - 34) / CGFloat(rows)).rounded(.down) : 102)
            : (size.height * 0.159 * 5 - fullScreenBarRoom) / CGFloat(rows)
        return CGSize(width: gridWidth / CGFloat(columns), height: height)
    }
    /// Centre of the first row's icons; the grid view starts half a row above it.
    var firstIconCenterY: CGFloat { size.height * 0.177 }
    var gridTop: CGFloat {
        windowed ? (categoryBar ? 100 : 66) : (firstIconCenterY - size.height * 0.159 * 5 / CGFloat(rows) / 2).rounded() + fullScreenBarRoom
    }
    var gridHeight: CGFloat { cellSize.height * CGFloat(rows) }
    /// Frame of the icon image. macOS icons leave ~10% transparent margin on each side,
    /// so the visible artwork is 80% of this, i.e. 6% of the screen width.
    /// Larger settings may grow into the cell's spare room, but never past it or into the label.
    var iconSize: CGFloat {
        let s = iconScale
        return windowed
            ? min(84 * s, cellSize.width * min(0.68 * s, 0.85), cellSize.height * min(0.75 * s, hideNames ? 0.9 : 0.8)).rounded()
            : min(size.width * 0.075 * s, cellSize.width * min(0.62 * s, 0.9), cellSize.height * min(0.72 * s, hideNames ? 0.95 : 0.84)).rounded()
    }
    var labelSize: CGFloat { 13 }
    /// Space between the icon frame and the label (the icon's own margin adds ~10% more).
    var labelGap: CGFloat { (iconSize * 0.02).rounded() }
    /// How far the icon+label stack's centre sits below the icon's centre.
    var stackOffset: CGFloat { hideNames ? 0 : (labelGap + labelSize * 1.25) / 2 }

    /// Whether `point` falls on a cell placed at `stack` (its `.position`): on the visible icon
    /// or on its name, not the empty room around them.
    func cellContains(_ point: CGPoint, stack: CGPoint, title: String, scale: CGFloat = 1) -> Bool {
        let icon = CGPoint(x: stack.x, y: stack.y - stackOffset * scale)
        // The artwork is 80% of the icon frame; a few points of slack around it.
        let half = (iconSize * 0.4 + 4) * scale
        if abs(point.x - icon.x) <= half, abs(point.y - icon.y) <= half { return true }
        guard !hideNames else { return false }
        let top = icon.y + (iconSize / 2 + labelGap) * scale
        let text = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: labelSize)]).width
        let width = (min(cellSize.width - 8, text) + 8) * scale
        return abs(point.x - icon.x) <= width / 2 && point.y >= top - 2 && point.y <= top + labelSize * 1.3 * scale
    }

    /// Icon centre of a home-grid slot, in launcher coordinates.
    func iconCenter(slot: Int) -> CGPoint {
        CGPoint(
            x: gridOriginX + (CGFloat(slot % columns) + 0.5) * cellSize.width,
            y: gridTop + (CGFloat(slot / columns) + 0.5) * cellSize.height
        )
    }

    // Folder panel: as wide as the home grid, icons on the home
    // columns and row pitch, height fitted to its rows (up to 5), centred at 51% height,
    // name floating above the panel.
    var folderItemCount = 0
    /// A smart folder's query line sits between its name and the panel.
    var folderHasQuery = false
    var hideNames = false
    /// The icon size setting, 1 being the default.
    var iconScale: CGFloat = 1
    var folderVisibleRows: Int { min(folderRows, max(1, (folderItemCount + folderColumns - 1) / folderColumns)) }
    /// Panel top to the first row's icon centre. Window mode centres the rows of icons and
    /// names in the panel, the same space above the first icon as below the last name.
    var folderIconInset: CGFloat {
        guard windowed else {
            // In step with the row height, so with more (shorter) rows the names stay inside the panel.
            let label = hideNames ? 0 : labelGap + labelSize * 1.25
            let fit = folderPanelRect.height - CGFloat(folderVisibleRows - 1) * cellSize.height - iconSize / 2 - label - 4
            return min(cellSize.height * 0.462, fit).rounded()
        }
        let label = hideNames ? 0 : labelGap + labelSize * 1.25
        let block = CGFloat(folderVisibleRows - 1) * cellSize.height + iconSize + label
        return ((folderPanelRect.height - block) / 2 + iconSize / 2).rounded()
    }
    var folderCornerRadius: CGFloat { windowed ? 26 : (size.width * 0.025).rounded() }
    var folderPanelRect: CGRect {
        let h = (CGFloat(folderVisibleRows) * cellSize.height + (windowed ? 32 : size.height * 0.01)).rounded()
        // A windowed folder with less than a row hugs its apps (at least three cells wide)
        // instead of stretching a lone app across the window.
        let w = windowed ? min(gridWidth, CGFloat(min(folderColumns, max(3, folderItemCount))) * cellSize.width + 32) : gridWidth
        return CGRect(x: ((size.width - w) / 2).rounded(), y: (size.height * 0.51 - h / 2).rounded(), width: w, height: h)
    }
    /// Columns the open folder's apps take up: all of them unless it has less than a row.
    private var folderShownColumns: Int { windowed ? min(folderColumns, max(1, folderItemCount)) : folderColumns }
    var folderTitleCenterY: CGFloat { folderPanelRect.minY - folderTitleGap }
    var folderGridRect: CGRect {
        let panel = folderPanelRect
        let width = min(panel.width, CGFloat(folderShownColumns) * cellSize.width)
        return CGRect(x: (panel.midX - width / 2).rounded(), y: panel.minY + folderIconInset - cellSize.height / 2,
                      width: width, height: CGFloat(folderVisibleRows) * cellSize.height)
    }
    /// How far a cell's name reaches below its row: with many rows in a small window the icon
    /// and name are taller than the row. The open folder's clip extends by this so the last
    /// row's names aren't cut off (it still stays inside the panel).
    /// Scroll browsing: the scroller's height, and the room after the last row so its names
    /// clear the bottom fade.
    var scrollViewport: CGFloat { size.height - gridTop - size.height * 0.03 }
    var scrollTail: CGFloat { (scrollViewport * 0.05 + labelOverflow + 6).rounded() }
    var labelOverflow: CGFloat {
        hideNames ? 0 : max(0, (iconSize / 2 + labelGap + labelSize * 1.25 + 2 - cellSize.height / 2).rounded(.up))
    }
    /// Icon centre of a slot on the current folder page, in launcher coordinates.
    func folderIconCenter(slot: Int) -> CGPoint {
        let grid = folderGridRect
        let s = slot
        return CGPoint(
            x: grid.minX + (CGFloat(s % folderColumns) + 0.5) * cellSize.width,
            y: grid.minY + (CGFloat(s / folderColumns) + 0.5) * cellSize.height
        )
    }
}
