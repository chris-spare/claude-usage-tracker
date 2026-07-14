import AppKit

/// Renders the usage arcs into donut circles and composites them side by side into
/// the single status-item image: 5-hour, 7-day, and (when present) month-to-date
/// spend. All three share one layered scheme, filling clockwise from 12 o'clock:
///   1. a gray disc (the empty remainder),
///   2. the overlap wedge [0 … min(time,usage)] in yellow,
///   3. the surplus wedge [min … max] in blue (time leads) or red (usage leads),
///   4. a black hole punched in the center with a small white label (5h / 7d / $),
///   5. a thin white outline.
/// The "time" layer is elapsed window time for 5h/7d, and elapsed calendar-month
/// time for spend; the "usage" layer is utilization for 5h/7d and used/limit for spend.
enum PieChart {
    // Palette.
    static let yellow = NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1) // overlap
    static let blue   = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1) // under pace
    static let red    = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1) // over pace
    // Untouched remainder — black. (Gray was too close to the blue "under pace"
    // wedge to distinguish.)
    static let disc   = NSColor.black
    // Subtle hairline ring (thin and semi-transparent) rather than a bold white edge.
    static let outline = NSColor(white: 1, alpha: 0.5)

    // Geometry (points). Pies + gaps, sized to fill the menu-bar height (no caption
    // row — a taller image gets scaled down, which shrinks the pies).
    static let diameter: CGFloat = 15
    static let gap: CGFloat = 5
    static let outlineWidth: CGFloat = 0.5
    /// Donut hole as a fraction of the pie radius (just big enough for the center
    /// label). The hole is black with the label centered in white.
    static let holeRatio: CGFloat = 0.7
    static let holeColor = NSColor.black
    static let centerLabelColor = NSColor(white: 0.8, alpha: 1)
    static let errorColor = NSColor.systemYellow   // the 4th warning glyph
    static let centerLabelFontSize: CGFloat = 5.5
    static func size(circles: Int) -> NSSize {
        NSSize(width: CGFloat(circles) * diameter + CGFloat(max(0, circles - 1)) * gap,
               height: diameter + 2)
    }

    /// Compose the pies into one image for the status item. The spend circle is
    /// included only when `extraUsage` is present; a warning glyph is appended when
    /// `showError` is set (the last fetch failed). Missing window buckets draw as an
    /// empty disc. All three donuts use the same layered scheme (yellow overlap,
    /// blue when time leads, red when usage leads) — for spend, the "time" layer is
    /// how far through the calendar month we are, against the effective limit.
    static func trayImage(fiveHour: UsageBucket?, sevenDay: UsageBucket?,
                          extraUsage: ExtraUsage? = nil, customLimitCents: Double? = nil,
                          showError: Bool = false, now: Date = Date()) -> NSImage {
        var slots = 2
        if extraUsage != nil { slots += 1 }
        if showError { slots += 1 }
        let size = size(circles: slots)
        let image = NSImage(size: size, flipped: false) { _ in
            let y = (size.height - diameter) / 2
            func rect(_ i: Int) -> NSRect {
                NSRect(x: CGFloat(i) * (diameter + gap), y: y, width: diameter, height: diameter)
            }
            drawPie(bucket: fiveHour, window: UsageWindow.fiveHour, in: rect(0), now: now, label: "5h")
            drawPie(bucket: sevenDay, window: UsageWindow.sevenDay, in: rect(1), now: now, label: "7d")
            var next = 2
            if let extraUsage {
                drawPie(time: UsageMath.monthTimeFraction(now: now),
                        usage: UsageMath.spendFraction(extraUsage, customLimitCents: customLimitCents),
                        in: rect(next), label: "$")
                next += 1
            }
            if showError { drawErrorIcon(in: rect(next)) }
            return true
        }
        image.isTemplate = false   // we draw real colors, not a monochrome template
        return image
    }

    /// Draw a warning triangle (last-fetch-failed indicator) fitted to `rect`.
    private static func drawErrorIcon(in rect: NSRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "fetch error")?
            .withSymbolConfiguration(cfg) else { return }
        let s = symbol.size
        let scale = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        let dst = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        let tinted = NSImage(size: dst.size, flipped: false) { r in
            symbol.draw(in: r)
            errorColor.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Draw one donut for a bucket (or an empty ring when nil) inside `rect`.
    private static func drawPie(bucket: UsageBucket?, window: TimeInterval, in rect: NSRect,
                                now: Date, label: String) {
        let time = bucket.map { UsageMath.timeFraction(resetsAt: $0.resetsAt, window: window, now: now) } ?? 0
        let usage = bucket.map { UsageMath.usageFraction(utilization: $0.utilization) } ?? 0
        drawPie(time: time, usage: usage, in: rect, label: label)
    }

    /// Draw one donut from already-computed fractions. Exposed for previews/tests.
    static func drawPie(time: Double, usage: Double, in rect: NSRect, label: String = "") {
        let inset = outlineWidth / 2 + 0.25
        let r = min(rect.width, rect.height) / 2 - inset
        let center = NSPoint(x: rect.midX, y: rect.midY)

        // Empty remainder.
        disc.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()

        let seg = UsageMath.segments(time: time, usage: usage)
        fillWedge(center: center, radius: r, from: 0, to: seg.yellowEnd, color: yellow)
        fillWedge(center: center, radius: r, from: seg.yellowEnd, to: seg.surplusEnd,
                  color: seg.timeLeads ? blue : red)

        // Punch the donut hole (black) and label it.
        let holeR = r * holeRatio
        holeColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - holeR, y: center.y - holeR,
                                    width: 2 * holeR, height: 2 * holeR)).fill()
        strokeOutline(center: center, radius: r)
        if !label.isEmpty { drawCenterLabel(label, at: center) }
    }

    /// Draw the tiny white label centered in the donut hole. The "$" glyph reads
    /// small next to "5h"/"7d", so it gets a larger point size (~1.6× via bumps).
    private static func drawCenterLabel(_ text: String, at center: NSPoint) {
        let size = text == "$" ? centerLabelFontSize * 1.600225 : centerLabelFontSize
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: centerLabelColor,
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2),
                                withAttributes: attrs)
    }

    /// The hairline ring around a pie.
    private static func strokeOutline(center: NSPoint, radius r: CGFloat) {
        outline.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = outlineWidth
        ring.stroke()
    }

    /// Fill a pie wedge spanning fractions [a, b] of the circle, measured clockwise
    /// from 12 o'clock. Built by sampling points along the arc so it does not depend
    /// on any arc-direction API convention.
    private static func fillWedge(center: NSPoint, radius r: CGFloat,
                                  from a: Double, to b: Double, color: NSColor) {
        guard b > a, r > 0 else { return }
        let path = NSBezierPath()
        path.move(to: center)
        // ~1° per step, at least 2 steps.
        let steps = max(2, Int((b - a) * 360))
        for i in 0...steps {
            let f = a + (b - a) * Double(i) / Double(steps)
            // f=0 → 90° (north); increasing f decreases the angle → clockwise.
            let angle = (90.0 - f * 360.0) * .pi / 180.0
            path.line(to: NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle)))
        }
        path.close()
        color.setFill()
        path.fill()
    }
}
