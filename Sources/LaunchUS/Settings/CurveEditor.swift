import SwiftUI

/// Picks the transitions' timing: the built-in springs, a preset, or a curve dragged by hand.
struct MotionCurvePicker: View {
    @Binding var curve: MotionCurve?

    private var label: String {
        guard let curve else { return String(localized: "系统弹簧") }
        return MotionCurve.presets.first { $0.curve == curve }?.title ?? String(localized: "自定义")
    }

    var body: some View {
        Menu(label) {
            Button(String(localized: "系统弹簧")) { curve = nil }
            Divider()
            ForEach(MotionCurve.presets) { preset in
                Button(preset.title) { curve = preset.curve }
            }
        }
        .fixedSize()
    }
}

/// A cubic Bézier curve with two handles to drag, and a dot that runs along it as a preview.
struct CurveEditor: View {
    @Binding var curve: MotionCurve

    private static let width: CGFloat = 176
    private static let unitY: CGFloat = 80
    private static let pad: CGFloat = 10
    private var range: ClosedRange<Double> { MotionCurve.yRange }
    private var height: CGFloat { CGFloat(range.upperBound - range.lowerBound) * Self.unitY }

    @State private var dragging: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            canvas
            Preview(curve: curve).frame(width: Self.width + Self.pad * 2)
            Text(String(format: "cubic-bezier(%.2f, %.2f, %.2f, %.2f)", curve.x1, curve.y1, curve.x2, curve.y2))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func toView(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: Self.pad + CGFloat(x) * Self.width,
                y: Self.pad + CGFloat(range.upperBound - y) * Self.unitY)
    }

    private func fromView(_ p: CGPoint) -> (Double, Double) {
        (Double((p.x - Self.pad) / Self.width), range.upperBound - Double((p.y - Self.pad) / Self.unitY))
    }

    private var canvas: some View {
        let start = toView(0, 0), end = toView(1, 1)
        let h1 = toView(curve.x1, curve.y1), h2 = toView(curve.x2, curve.y2)
        return ZStack(alignment: .topLeading) {
            // The 0…1 box: where the curve starts and ends; above or below it overshoots.
            Path { $0.addRect(CGRect(x: start.x, y: end.y, width: end.x - start.x, height: start.y - end.y)) }
                .fill(Color.primary.opacity(0.05))
            Path { $0.addRect(CGRect(x: start.x, y: end.y, width: end.x - start.x, height: start.y - end.y)) }
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            Path { $0.move(to: start); $0.addLine(to: end) }
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Path { $0.move(to: start); $0.addLine(to: h1); $0.move(to: end); $0.addLine(to: h2) }
                .stroke(Color.secondary.opacity(0.7), lineWidth: 1)
            Path { $0.move(to: start); $0.addCurve(to: end, control1: h1, control2: h2) }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            ForEach([start, end], id: \.x) { p in
                Circle().fill(Color.secondary).frame(width: 6, height: 6).position(p)
            }
            handle(h1, active: dragging == 1)
            handle(h2, active: dragging == 2)
        }
        .frame(width: Self.width + Self.pad * 2, height: height + Self.pad * 2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragging == nil {
                        let d1 = hypot(value.startLocation.x - h1.x, value.startLocation.y - h1.y)
                        let d2 = hypot(value.startLocation.x - h2.x, value.startLocation.y - h2.y)
                        dragging = d1 <= d2 ? 1 : 2
                    }
                    let (x, y) = fromView(value.location)
                    // Two decimals is all anyone can see, and it keeps saved values tidy.
                    let rx = (x * 100).rounded() / 100, ry = (y * 100).rounded() / 100
                    var next = curve
                    if dragging == 1 { next.x1 = rx; next.y1 = ry } else { next.x2 = rx; next.y2 = ry }
                    curve = next.clamped
                }
                .onEnded { _ in dragging = nil }
        )
    }

    private func handle(_ p: CGPoint, active: Bool) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: active ? 15 : 13, height: active ? 15 : 13)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .position(p)
    }
}

/// A dot crossing a track over and over, timed by the curve.
private struct Preview: View {
    let curve: MotionCurve
    private let run = 0.6, rest = 0.5

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: run + rest)
            let progress = t < run ? curve.value(at: t / run) : 1
            GeometryReader { geo in
                let travel = geo.size.width - 14
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07)).frame(height: 4)
                    Circle().fill(Color.accentColor).frame(width: 14, height: 14)
                        .offset(x: travel * progress)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 16)
    }
}
