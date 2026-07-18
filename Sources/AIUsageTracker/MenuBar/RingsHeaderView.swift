import AppKit

/// A dropdown-menu header that shows a large version of the same circles drawn in
/// the status bar, laid out side by side. Under each ring, top to bottom: a heading
/// (the provider name, or the dollar value for the cost pie), the caption ("5-Hour",
/// "Cost", …), a "Usage: n%" line, and a column-width sparkline of that metric's
/// recent rate. Fed the same `PieChart.Circle` list as the tray image, so the two
/// always agree. Draws nothing until `circles` is set.
@MainActor
final class RingsHeaderView: NSView {
    /// The circles to render (in order); text/values/series come from each `Circle`.
    var circles: [PieChart.Circle] = [] {
        didSet {
            setFrameSize(NSSize(width: preferredWidth, height: preferredHeight))
            needsDisplay = true
        }
    }

    // Layout (points).
    private let ringDiameter: CGFloat = 42
    private let columnWidth: CGFloat = 80   // per-circle column (ring + text)
    /// Inter-column gap scales with column count: the original 18pt at 3 columns down
    /// to 0 at 5 (packed tight when crowded), linearly interpolated between — so 27pt
    /// at 2 columns, 9pt at 4. gap(n) = max(0, 45 − 9n).
    private var columnGap: CGFloat { max(0, 45 - 9 * CGFloat(circles.count)) }
    private let leftMargin: CGFloat = 21    // aligns with the standard menu-text indent
    private let minWidth: CGFloat = 220
    private let topPad: CGFloat = 12
    private let captionGap: CGFloat = 6      // ring → heading
    private let headingHeight: CGFloat = 14
    private let captionHeight: CGFloat = 15
    private let lineGap: CGFloat = 3         // between text lines
    private let statHeight: CGFloat = 13
    private let sparkHeight: CGFloat = 22
    private static let sparkGapThreshold: TimeInterval = 8 * 60

    private var groupWidth: CGFloat {
        guard !circles.isEmpty else { return 0 }
        return CGFloat(circles.count) * columnWidth + CGFloat(circles.count - 1) * columnGap
    }
    var preferredWidth: CGFloat { max(minWidth, leftMargin + groupWidth + leftMargin) }
    var preferredHeight: CGFloat {
        // ring + heading + caption + Usage + Elapsed + sparkline, with gaps between.
        topPad + ringDiameter + captionGap + headingHeight + lineGap + captionHeight
            + lineGap + statHeight + lineGap + statHeight + lineGap + sparkHeight + bottomPad
    }
    private let bottomPad: CGFloat = 8

    private static let headingAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    private static let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
    ]
    private static let statAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard !circles.isEmpty else { return }
        let ringY = bounds.height - topPad - ringDiameter

        for (i, circle) in circles.enumerated() {
            let colX = leftMargin + CGFloat(i) * (columnWidth + columnGap)
            let ringRect = NSRect(x: colX + (columnWidth - ringDiameter) / 2, y: ringY,
                                  width: ringDiameter, height: ringDiameter)
            PieChart.draw(circle, in: ringRect)

            // Text lines, top-down, each centered in the column.
            var y = ringY - captionGap - headingHeight
            if let heading = circle.heading {
                drawLine(heading, attrs: Self.headingAttrs, columnX: colX, bottomY: y, height: headingHeight)
            }
            y -= lineGap + captionHeight
            drawLine(circle.caption, attrs: Self.captionAttrs, columnX: colX, bottomY: y, height: captionHeight)

            guard case .pie(let time, let usage) = circle.kind else { continue }
            y -= lineGap + statHeight
            drawLine("Usage: \(pct(usage))%", attrs: Self.statAttrs, columnX: colX, bottomY: y, height: statHeight)
            y -= lineGap + statHeight
            drawLine("Elapsed: \(pct(time))%", attrs: Self.statAttrs, columnX: colX, bottomY: y, height: statHeight)
            // Column-width sparkline of the recent usage rate, below the stats.
            // Only drawn once there are ≥2 points (else it'd be an empty axis).
            guard circle.spark.count >= 2 else { continue }
            y -= lineGap + sparkHeight
            let sparkRect = NSRect(x: colX, y: y, width: columnWidth, height: sparkHeight)
            Sparkline.draw(points: UsageMath.usageRatePoints(circle.spark),
                           window: UsageHistory.sparklineWindow, now: Date(),
                           in: sparkRect, color: .labelColor, gapThreshold: Self.sparkGapThreshold,
                           leftInset: 2, rightInset: 2, vInset: 3)
        }
    }

    private func pct(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

    private func drawLine(_ text: String, attrs: [NSAttributedString.Key: Any],
                          columnX x: CGFloat, bottomY: CGFloat, height: CGFloat) {
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: x + (columnWidth - size.width) / 2, y: bottomY + (height - size.height) / 2),
                 withAttributes: attrs)
    }
}
