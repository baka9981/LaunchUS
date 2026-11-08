import SwiftUI
import AppKit

struct ScrollGrid: View {
    let model: LauncherModel
    let metrics: GridMetrics
    @State private var position = ScrollPosition(edge: .top)
    /// The top row in view. Only rows near it are built: a few hundred icons at once made
    /// every scroll, right-click and icon update re-run all of them.
    @State private var firstRow = 0

    var body: some View {
        // Pages run together here without their empty cells, packed again around widgets.
        let flat = model.scrollCells
        let phantom = model.phantomScrollSlot
        let rowCount = max(1, (flat.count + (phantom ? 1 : 0) + metrics.columns - 1) / metrics.columns)
        let height = metrics.scrollViewport
        // The recent apps row scrolls with the grid, above it, as in the system Apps window.
        let lead = model.scrollLead
        let showsRow = lead > 0
        let cellH = metrics.cellSize.height
        let shownRows = Int((height / cellH).rounded(.up))
        let end = min(flat.count, (firstRow + shownRows + 2) * metrics.columns)
        // A few rows more above, for the lower part of a tall widget that starts out of view.
        let built = min(end, max(0, (firstRow - 4) * metrics.columns))..<end
            ScrollView(.vertical, showsIndicators: metrics.windowed) {
                ZStack(alignment: .topLeading) {
                    if showsRow {
                        FrequentRow(model: model, metrics: metrics)
                            .frame(width: metrics.gridWidth, height: lead)
                            .offset(x: metrics.gridOriginX)
                            .allowsHitTesting(!model.isEditing)
                            .zIndex(1)
                    }
                    ForEach(Array(flat.enumerated())[built].filter { !$0.element.entry.isGap }, id: \.element.entry.id) { index, item in
                        let x = metrics.gridOriginX + (CGFloat(index % metrics.columns) + 0.5) * metrics.cellSize.width
                        let y = lead + (CGFloat(index / metrics.columns) + 0.5) * metrics.cellSize.height
                        if let widget = item.entry.widget {
                            let rect = metrics.widgetRect(first: CGPoint(x: x, y: y), span: widget.size.span(columns: metrics.columns, rows: metrics.rows))
                            WidgetCell(widget: widget, model: model, metrics: metrics,
                                       rect: rect.offsetBy(dx: 0, dy: metrics.gridTop),
                                       selected: model.openFolderID == nil && model.selection == item.pos)
                                .fixedSize()
                                .position(x: rect.midX, y: rect.minY + WidgetCell.height(rect, metrics) / 2)
                        } else {
                        EntryView(
                            entry: item.entry, model: model, metrics: metrics,
                            center: CGPoint(x: x, y: y + metrics.gridTop), folderID: nil,
                            selected: model.openFolderID == nil && model.selection == item.pos
                        )
                        .frame(maxWidth: metrics.cellSize.width - 8)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: x, y: y + metrics.stackOffset)
                        }
                    }
                    if phantom {
                        let x = metrics.gridOriginX + (CGFloat(flat.count % metrics.columns) + 0.5) * metrics.cellSize.width
                        let y = lead + (CGFloat(flat.count / metrics.columns) + 0.5) * metrics.cellSize.height
                        PhantomSlot(model: model, metrics: metrics).position(x: x, y: y)
                    }
                }
                .frame(width: metrics.size.width, height: max(height, lead + CGFloat(rowCount) * metrics.cellSize.height + metrics.scrollTail), alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { model.backgroundTapped() }
                // This grid covers the background (at least the whole view, even with few icons),
                // so empty space closes the launcher on a click and shows the background's menu.
                .nativeContextMenu(at: { point in
                    let index = flat.indices.first { index in
                        guard !flat[index].entry.isGap else { return false }
                        let x = metrics.gridOriginX + (CGFloat(index % metrics.columns) + 0.5) * metrics.cellSize.width
                        let y = lead + (CGFloat(index / metrics.columns) + 0.5) * metrics.cellSize.height
                        if let widget = flat[index].entry.widget {
                            return metrics.widgetRect(first: CGPoint(x: x, y: y), span: widget.size.span(columns: metrics.columns, rows: metrics.rows)).contains(point)
                        }
                        return metrics.cellContains(point, stack: CGPoint(x: x, y: y + metrics.stackOffset), title: flat[index].entry.title)
                    }
                    if let index { return EntryView.menu(flat[index].entry, folderID: nil, model: model) }
                    // The secret slot after the last app takes its own right-click.
                    if phantom {
                        let x = metrics.gridOriginX + (CGFloat(flat.count % metrics.columns) + 0.5) * metrics.cellSize.width
                        let y = lead + (CGFloat(flat.count / metrics.columns) + 0.5) * metrics.cellSize.height
                        let half = metrics.iconSize * 0.4 + 4
                        if abs(point.x - x) <= half, abs(point.y - y) <= half { return nil }
                    }
                    return LauncherMenus.main(model)
                })
            }
            .frame(width: metrics.size.width, height: height)
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                model.gridScrollOffset = y
                let row = max(0, Int((y - lead) / cellH))
                if row != firstRow { firstRow = row }
                // A held icon now hovers over another cell.
                if model.drag != nil { model.dragMoved(to: model.dragLocation) }
            }
            .onChange(of: model.gridScrollRequest) { _, y in
                if let y { position.scrollTo(y: y) }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                         .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: model.scrollToTopRequest) { _, _ in position.scrollTo(edge: .top) }
            .onChange(of: model.selection) { _, pos in
                // Keyboard selection: bring its row into view (it may not be built yet).
                guard let pos, let index = flat.firstIndex(where: { $0.pos == pos }) else { return }
                let top = lead + CGFloat(index / metrics.columns) * cellH
                let offset = model.gridScrollOffset
                let y = top < offset ? top : top + cellH > offset + height ? top + cellH - height : nil
                if let y { withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(y: y) } }
            }
    }
}

/// A short bar of light with a soft glow, like an LED strip.
struct LightStrip: View {
    let color: Color
    let pulsing: Bool
    let windowed: Bool
    @State private var bright = true

    var body: some View {
        let core = windowed && color == .white ? Color.primary.opacity(0.6) : color
        Capsule()
            .fill(LinearGradient(colors: [core.opacity(0), core, core, core.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(Capsule().fill(.white.opacity(0.85)).frame(height: 1.5).padding(.horizontal, 8))
            .shadow(color: core.opacity(bright ? 1 : 0.55), radius: bright ? 5 : 3)
            .shadow(color: core.opacity(bright ? 0.75 : 0.3), radius: bright ? 12 : 6)
            .opacity(bright ? 1 : 0.7)
            .onAppear {
                guard pulsing else { return }
                bright = false
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { bright = true }
            }
            .allowsHitTesting(false)
    }
}

/// A capsule message that fades in above the page dots.
/// The answer to a sum or unit conversion typed into search. Click or Return copies it.
struct CalculationCard: View {
    let result: Calculator.Result
    let windowed: Bool
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            VStack(spacing: 6) {
                Text(verbatim: result.expression)
                    .font(.system(size: 15))
                    .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.7)))
                Text(verbatim: result.display)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                    .lineLimit(1).minimumScaleFactor(0.4)
                Text("按 ↩ 或点按复制结果")
                    .font(.system(size: 12))
                    .foregroundStyle(windowed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white.opacity(0.55)))
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .frame(width: SearchCard.width)
            .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.35)),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(result.expression) \(result.display)"))
    }
}

/// The cards under the search field (sum, nothing found, files, AI chat) share one width so they line up.
enum SearchCard {
    static let width: CGFloat = 580
}

/// Search found nothing: ask AI (↩) when it is set up, search the web (↩, or ⇥ with AI) or Finder (⌘↩).
struct FallbackCard: View {
    let text: String
    let engine: String
    let windowed: Bool
    let web: () -> Void
    let finder: () -> Void
    /// Set when AI is configured.
    let ai: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Text("没有找到「\(text)」")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(windowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.75)))
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                if let ai {
                    choice(String(localized: "问 AI"), symbol: "sparkles", key: "↩", action: ai)
                }
                choice(String(localized: "用 \(engine) 搜索"), symbol: "globe", key: ai == nil ? "↩" : "⇥", action: web)
                choice(String(localized: "在访达中搜索"), symbol: "magnifyingglass", key: "⌘↩", action: finder)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .frame(width: SearchCard.width)
        .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private func choice(_ title: String, symbol: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
                Text(verbatim: key).foregroundStyle(windowed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white.opacity(0.5)))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(windowed ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct NoticeToast: View {
    let text: String
    let windowed: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(windowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(windowed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black.opacity(0.45)), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(windowed ? 0 : 0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
