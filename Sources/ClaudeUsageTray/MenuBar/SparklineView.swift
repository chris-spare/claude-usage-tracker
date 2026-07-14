import AppKit

/// Draws a minimal single-metric line sparkline into a rect. With `zeroBaseline`
/// the vertical scale runs 0…max (so quiet periods rest on the bottom line and
/// bursts spike up); otherwise it auto-scales to the data's own min…max. Draws
/// nothing with fewer than two points. Kept as a free function so both the menu
/// view and the debug preview share it.
enum Sparkline {
    static func draw(values: [Double], in rect: NSRect, color: NSColor,
                     zeroBaseline: Bool = false,
                     leftInset: CGFloat = 21, rightInset: CGFloat = 16, vInset: CGFloat = 5) {
        guard values.count >= 2 else { return }
        let w = rect.width - leftInset - rightInset
        let h = rect.height - 2 * vInset
        guard w > 0, h > 0 else { return }
        let x0 = rect.minX + leftInset
        let x1 = x0 + w
        let yBottom = rect.minY + vInset
        let yTop = yBottom + h

        // Faint hairlines framing the plotted range (bottom = zero for a rate
        // sparkline), so a flat/near-flat line is unambiguously placed.
        color.withAlphaComponent(0.18).setStroke()
        for y in [yBottom, yTop] {
            let guideLine = NSBezierPath()
            guideLine.move(to: NSPoint(x: x0, y: y))
            guideLine.line(to: NSPoint(x: x1, y: y))
            guideLine.lineWidth = 0.5
            guideLine.stroke()
        }

        let lo = zeroBaseline ? 0 : values.min()!
        let hi = max(values.max()!, lo)
        let range = hi - lo
        // With a zero baseline a flat series rests on the bottom (zero) line;
        // otherwise it floats at mid-height.
        let flatY = yBottom + (zeroBaseline ? 0 : h / 2)
        let path = NSBezierPath()
        for (i, v) in values.enumerated() {
            let x = x0 + w * CGFloat(i) / CGFloat(values.count - 1)
            // Higher value → higher on screen (non-flipped coords).
            let y = range > 0 ? yBottom + h * CGFloat((v - lo) / range) : flatY
            let p = NSPoint(x: x, y: y)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.lineWidth = 1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

/// A menu-item view hosting one sparkline of *usage rate* — the per-fetch delta of
/// its metric — so it spikes during bursts and rests near zero when idle. Drawn in
/// the adaptive label color (white in dark mode, near-black in light mode). Assign
/// the raw cumulative series; the view derives the rate itself.
@MainActor
final class SparklineView: NSView {
    /// Raw cumulative series (utilization % or spend cents), oldest first.
    var values: [Double] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        Sparkline.draw(values: UsageMath.usageRateSeries(values), in: bounds,
                       color: .labelColor, zeroBaseline: true)
    }
}
