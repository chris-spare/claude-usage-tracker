import AppKit

/// Renders usage into circles composited side by side into the single status-item
/// image: 5-hour, 7-day, and (when present) month-to-date spend. Each circle draws
/// two independent layers, both filling clockwise from 12 o'clock:
///   1. a black disc (the empty remainder),
///   2. the "time" layer as a solid gray pie wedge [0 … time] spanning the full
///      radius (occupying both lanes),
///   3. the "usage" layer as a white ring [0 … usage] in the outer lane, drawn over
///      top of the time wedge,
///   4. a thin hairline outline.
/// Time and usage occupy separate lanes, so they never need to be reconciled into a
/// single wedge. The "time" layer is elapsed window time for 5h/7d, and elapsed
/// calendar-month time for spend; the "usage" layer is utilization for 5h/7d and
/// used/limit for spend.
enum PieChart {
    // Palette.
    /// Elapsed-time pie — a solid gray wedge across the full radius.
    static let timeColor = NSColor(white: 0.5, alpha: 1)
    /// Usage ring — white, drawn over the time wedge in the outer lane.
    static let usageColor = NSColor.white
    // Untouched remainder — black.
    static let disc   = NSColor.black
    // Subtle hairline ring (thin and semi-transparent) rather than a bold white edge.
    static let outline = NSColor(white: 1, alpha: 0.5)

    // Geometry (points). Pies + gaps, sized to fill the menu-bar height (no caption
    // row — a taller image gets scaled down, which shrinks the pies).
    static let diameter: CGFloat = 15
    static let gap: CGFloat = 5
    static let outlineWidth: CGFloat = 0.5
    /// Inner edge of the usage ring, as a fraction of the pie radius. The ring
    /// occupies the outer lane [ringInnerRatio·r … r]; the time wedge fills the whole
    /// disc beneath it.
    static let ringInnerRatio: CGFloat = 0.67
    static let errorColor = NSColor.systemYellow   // the 4th warning glyph
    static func size(circles: Int) -> NSSize {
        NSSize(width: CGFloat(circles) * diameter + CGFloat(max(0, circles - 1)) * gap,
               height: diameter + 2)
    }

    /// One circle's already-computed fractions plus a short caption. This is the
    /// single source of truth shared by the tray image and the dropdown header, so
    /// the two never disagree about which circles to show or what they represent.
    struct Circle {
        var time: Double
        var usage: Double
        var caption: String
    }

    /// The ordered circles to display for a data snapshot: 5-hour, 7-day, and — only
    /// when there's a limit to measure spend against (custom or API) — month-to-date
    /// spend. Missing window buckets read as empty (0/0). The fetch-error glyph is
    /// not a circle; the tray appends it separately.
    static func circles(fiveHour: UsageBucket?, sevenDay: UsageBucket?,
                        extraUsage: ExtraUsage?, customLimitCents: Double?,
                        now: Date = Date()) -> [Circle] {
        var out = [
            circle(bucket: fiveHour, window: UsageWindow.fiveHour, now: now, caption: "5-Hour"),
            circle(bucket: sevenDay, window: UsageWindow.sevenDay, now: now, caption: "7-Day"),
        ]
        if UsageMath.showsSpendCircle(extraUsage, customLimitCents: customLimitCents), let extraUsage {
            out.append(Circle(time: UsageMath.monthTimeFraction(now: now),
                              usage: UsageMath.spendFraction(extraUsage, customLimitCents: customLimitCents),
                              caption: "Spend"))
        }
        return out
    }

    /// Compose the pies into one image for the status item. A warning glyph is
    /// appended when `showError` is set (the last fetch failed). All circles use the
    /// same layered scheme (gray time wedge, white usage ring over top) — for spend,
    /// the "time" layer is how far through the calendar month we are.
    static func trayImage(fiveHour: UsageBucket?, sevenDay: UsageBucket?,
                          extraUsage: ExtraUsage? = nil, customLimitCents: Double? = nil,
                          showError: Bool = false, now: Date = Date()) -> NSImage {
        let circles = circles(fiveHour: fiveHour, sevenDay: sevenDay, extraUsage: extraUsage,
                              customLimitCents: customLimitCents, now: now)
        let slots = circles.count + (showError ? 1 : 0)
        let size = size(circles: slots)
        let image = NSImage(size: size, flipped: false) { _ in
            let y = (size.height - diameter) / 2
            func rect(_ i: Int) -> NSRect {
                NSRect(x: CGFloat(i) * (diameter + gap), y: y, width: diameter, height: diameter)
            }
            for (i, c) in circles.enumerated() { drawPie(time: c.time, usage: c.usage, in: rect(i)) }
            if showError { drawErrorIcon(in: rect(circles.count)) }
            return true
        }
        image.isTemplate = false   // we draw real colors, not a monochrome template
        return image
    }

    /// Build a `Circle` from a window bucket (or an empty circle when nil).
    private static func circle(bucket: UsageBucket?, window: TimeInterval, now: Date,
                               caption: String) -> Circle {
        let time = bucket.map { UsageMath.timeFraction(resetsAt: $0.resetsAt, window: window, now: now) } ?? 0
        let usage = bucket.map { UsageMath.usageFraction(utilization: $0.utilization) } ?? 0
        return Circle(time: time, usage: usage, caption: caption)
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

    /// Draw one circle from already-computed fractions. Exposed for previews/tests.
    /// The time fraction is a solid gray pie wedge across the full radius; the usage
    /// fraction is a white ring in the outer lane, drawn over top.
    static func drawPie(time: Double, usage: Double, in rect: NSRect) {
        let inset = outlineWidth / 2 + 0.25
        let r = min(rect.width, rect.height) / 2 - inset
        let center = NSPoint(x: rect.midX, y: rect.midY)

        // Empty remainder.
        disc.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()

        // Time: a solid gray pie wedge spanning the whole radius (both lanes).
        fillWedge(center: center, radius: r, from: 0, to: time, color: timeColor)

        // Usage: a white ring in the outer lane, over top of the time wedge.
        fillRingWedge(center: center, innerRadius: r * ringInnerRatio, outerRadius: r,
                      from: 0, to: usage, color: usageColor)

        strokeOutline(center: center, radius: r)
    }

    /// The hairline ring around a pie.
    private static func strokeOutline(center: NSPoint, radius r: CGFloat) {
        outline.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = outlineWidth
        ring.stroke()
    }

    /// Point on the circle of radius `r` about `center` at fraction `f`, measured
    /// clockwise from 12 o'clock. f=0 → 90° (north); increasing f decreases the angle.
    private static func arcPoint(center: NSPoint, radius r: CGFloat, fraction f: Double) -> NSPoint {
        let angle = (90.0 - f * 360.0) * .pi / 180.0
        return NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
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
            path.line(to: arcPoint(center: center, radius: r, fraction: a + (b - a) * Double(i) / Double(steps)))
        }
        path.close()
        color.setFill()
        path.fill()
    }

    /// Fill an annular (ring) wedge spanning fractions [a, b] of the circle, between
    /// `innerR` and `outerR`, measured clockwise from 12 o'clock. Traces the outer arc
    /// forward, then the inner arc back.
    private static func fillRingWedge(center: NSPoint, innerRadius innerR: CGFloat, outerRadius outerR: CGFloat,
                                      from a: Double, to b: Double, color: NSColor) {
        guard b > a, outerR > innerR, innerR >= 0 else { return }
        let path = NSBezierPath()
        let steps = max(2, Int((b - a) * 360))
        for i in 0...steps {
            let f = a + (b - a) * Double(i) / Double(steps)
            let p = arcPoint(center: center, radius: outerR, fraction: f)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            path.line(to: arcPoint(center: center, radius: innerR, fraction: a + (b - a) * Double(i) / Double(steps)))
        }
        path.close()
        color.setFill()
        path.fill()
    }
}
