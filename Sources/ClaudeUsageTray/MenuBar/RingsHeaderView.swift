import AppKit

/// A dropdown-menu header that shows a large version of the same circles drawn in
/// the status bar, laid out side by side. Under each ring: a caption ("5-Hour",
/// "7-Day", "Spend") and two stat lines — "Usage: n%" (the white ring) and
/// "Elapsed: n%" (the gray time wedge). Fed the same `PieChart.Circle` list as the
/// tray image, so the two always agree. Draws nothing until `circles` is set.
@MainActor
final class RingsHeaderView: NSView {
    /// The circles to render (in order); captions/values come from each `Circle`.
    var circles: [PieChart.Circle] = [] {
        didSet {
            setFrameSize(NSSize(width: preferredWidth, height: preferredHeight))
            needsDisplay = true
        }
    }

    // Layout (points).
    private let ringDiameter: CGFloat = 42
    private let columnWidth: CGFloat = 80   // per-circle column (ring + text)
    private let columnGap: CGFloat = 18     // space between sections
    private let leftMargin: CGFloat = 21    // aligns with the standard menu-text indent
    private let minWidth: CGFloat = 220     // never narrower than the sparklines
    private let topPad: CGFloat = 12
    private let captionGap: CGFloat = 6      // ring → caption
    private let captionHeight: CGFloat = 15
    private let statGap: CGFloat = 3         // caption → stats, and stat → stat
    private let statHeight: CGFloat = 13
    private let bottomPad: CGFloat = 8

    private var groupWidth: CGFloat {
        guard !circles.isEmpty else { return 0 }
        return CGFloat(circles.count) * columnWidth + CGFloat(circles.count - 1) * columnGap
    }
    var preferredWidth: CGFloat { max(minWidth, leftMargin + groupWidth + leftMargin) }
    var preferredHeight: CGFloat {
        topPad + ringDiameter + captionGap + captionHeight + 3 * statGap + 2 * statHeight + bottomPad
    }

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
        // Left-align the columns to the standard menu-text indent.
        let ringY = bounds.height - topPad - ringDiameter

        for (i, circle) in circles.enumerated() {
            let colX = leftMargin + CGFloat(i) * (columnWidth + columnGap)
            let ringRect = NSRect(x: colX + (columnWidth - ringDiameter) / 2, y: ringY,
                                  width: ringDiameter, height: ringDiameter)
            PieChart.drawPie(time: circle.time, usage: circle.usage, in: ringRect)

            // Text lines, top-down, each centered in the column.
            var y = ringY - captionGap - captionHeight
            drawLine(circle.caption, attrs: Self.captionAttrs, columnX: colX, bottomY: y, height: captionHeight)
            y -= statGap + statHeight
            drawLine("Usage: \(pct(circle.usage))%", attrs: Self.statAttrs, columnX: colX, bottomY: y, height: statHeight)
            y -= statGap + statHeight
            drawLine("Elapsed: \(pct(circle.time))%", attrs: Self.statAttrs, columnX: colX, bottomY: y, height: statHeight)
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
