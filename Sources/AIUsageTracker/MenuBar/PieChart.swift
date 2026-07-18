import AppKit

/// Renders usage into circles composited side by side into the single status-item
/// image, one image shared with the dropdown header via the `Circle` list. Each
/// provider contributes its window pies (or a single warning glyph when its last
/// fetch failed), in `ProviderID` order, followed by the combined spend pie.
///
/// Each pie draws two independent layers, both filling clockwise from 12 o'clock:
///   1. a black disc (the empty remainder),
///   2. the "time" layer as a solid wedge [0 … time] across the full radius,
///   3. the "usage" layer as a ring [0 … usage] in the outer lane, over the wedge,
///   4. a thin hairline outline.
/// Colors come from the per-provider palette (usage ring + darkened time wedge);
/// the spend pie uses a red ring over a dimmed-red wedge.
enum PieChart {
    /// A provider's (or the spend pie's) two colors.
    struct Palette { let usage: NSColor; let time: NSColor }

    /// Per-provider palette: usage ring in the brand color, time wedge at 60%
    /// brightness. Claude #D97757, Codex #3D93D6, Cursor #AC7CE0.
    static func palette(for id: ProviderID) -> Palette {
        switch id {
        case .claude: return make(217, 119, 87)
        case .codex:  return make(61, 147, 214)
        case .cursor: return make(172, 124, 224)
        }
    }
    /// Combined spend pie: a red usage ring (#F04C4C, near the brand colors' perceived
    /// lightness) over a neutral gray time wedge.
    static let spendPalette = Palette(usage: NSColor(srgbRed: 240 / 255, green: 76 / 255, blue: 76 / 255, alpha: 1),
                                      time: NSColor(white: 0.5, alpha: 1))

    private static func make(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Palette {
        Palette(usage: NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1),
                time: NSColor(srgbRed: r / 255 * 0.6, green: g / 255 * 0.6, blue: b / 255 * 0.6, alpha: 1))
    }

    // Untouched remainder — black.
    static let disc = NSColor.black
    // Subtle hairline ring rather than a bold white edge.
    static let outline = NSColor(white: 1, alpha: 0.5)
    /// Thickness of the solid black rim around each pie, as a fraction of the radius
    /// (with an absolute floor). The rim vanishes into a dark background but separates
    /// the pie from a pale menu in light mode. Used by the menu rings, not the tray.
    static let borderRatio: CGFloat = 0.12
    static let borderMinWidth: CGFloat = 1

    // Geometry (points). The circle diameter tracks the live menu-bar height so the
    // tray icon fills it like other status items, rather than sitting small in the bar.
    // A ~4pt margin keeps the outline off the bar edges; the floor guards odd values.
    static var diameter: CGFloat { max(15, NSStatusBar.system.thickness - 4) }
    static let gap: CGFloat = 5
    static let outlineWidth: CGFloat = 0.5
    /// Inner edge of the usage ring, as a fraction of the pie radius (so the ring band
    /// is the outer 1/5 of the radius).
    static let ringInnerRatio: CGFloat = 0.8
    /// Radius of the white "maxed out" center dot (drawn at 100%), as a fraction of the
    /// pie radius.
    static let fullDotRatio: CGFloat = 0.13

    static func size(circles: Int) -> NSSize {
        let n = max(1, circles)   // always at least one slot so the tray item is clickable
        return NSSize(width: CGFloat(n) * diameter + CGFloat(n - 1) * gap, height: diameter + 2)
    }

    /// One circle: either a two-layer pie or a warning glyph (failed provider). The
    /// single source of truth shared by the tray image and the dropdown header, so
    /// the two never disagree about which slots to show or what they represent.
    struct Circle {
        enum Kind: Equatable {
            case pie(time: Double, usage: Double)
            case error
        }
        var kind: Kind
        /// Optional line drawn above the caption in the dropdown header: the provider
        /// name for a window/error circle, or the dollar value for the spend circle.
        /// Unused by the tray image.
        var heading: String?
        var caption: String
        var usageColor: NSColor
        var timeColor: NSColor
        /// Cumulative series (utilization % or spend cents, oldest first) feeding the
        /// per-column sparkline in the dropdown header. Unused by the tray image.
        var spark: [(Date, Double)]
        /// When this window/pie next resets (nil for an idle window). Drives the
        /// header column's "Reset: …" lines, computed live against the clock.
        var resetsAt: Date?
        /// Hover text for the pie (projected end-of-window usage) and the sparkline
        /// (recent peak rate), or nil when there isn't enough signal. Header-only.
        var pieTooltip: String?
        var sparkTooltip: String?

        init(kind: Kind, heading: String? = nil, caption: String,
             usageColor: NSColor, timeColor: NSColor, spark: [(Date, Double)] = [],
             resetsAt: Date? = nil, pieTooltip: String? = nil, sparkTooltip: String? = nil) {
            self.kind = kind
            self.heading = heading
            self.caption = caption
            self.usageColor = usageColor
            self.timeColor = timeColor
            self.spark = spark
            self.resetsAt = resetsAt
            self.pieTooltip = pieTooltip
            self.sparkTooltip = sparkTooltip
        }
    }

    /// The ordered circles for a tray view model: each enabled provider's window
    /// pies (or one warning glyph if it errored), then the combined spend pie when any
    /// provider reports spend. A provider that hasn't fetched yet contributes nothing.
    ///
    /// Each window's time wedge is computed at *that provider's* last-fetch moment
    /// (`lastUpdated`), not the live clock, so time never races ahead of the frozen
    /// usage reading and the time-vs-usage comparison stays fair between fetches.
    static func circles(from vm: TrayViewModel, now: Date = Date()) -> [Circle] {
        var out: [Circle] = []
        for p in vm.providers {
            let pal = palette(for: p.id)
            if p.error != nil {
                out.append(Circle(kind: .error, heading: p.displayName, caption: "unavailable",
                                  usageColor: pal.usage, timeColor: pal.time))
            } else if let snap = p.snapshot {
                let at = p.lastUpdated ?? now
                for w in snap.windows {
                    let series = p.series(forWindow: w.caption)
                    out.append(Circle(
                        kind: .pie(time: UsageMath.timeFraction(w.timeBasis, resetsAt: w.resetsAt, now: at),
                                   usage: UsageMath.usageFraction(utilization: w.utilization)),
                        heading: p.displayName, caption: w.caption,
                        usageColor: pal.usage, timeColor: pal.time,
                        spark: series,
                        resetsAt: w.resetsAt,
                        pieTooltip: UsageMath.projectedText(w, now: at),
                        sparkTooltip: UsageMath.recentPeakText(series, unit: .percent)))
                }
            }
        }
        if vm.hasAnySpend {
            out.append(Circle(
                kind: .pie(time: UsageMath.monthTimeFraction(now: vm.latestUpdate ?? now),
                           usage: UsageMath.spendFraction(usedCents: vm.combinedSpendCents,
                                                          limitCents: vm.customLimitCents)),
                heading: UsageMath.formatDollars(vm.combinedSpendCents), caption: "Spend",
                usageColor: spendPalette.usage, timeColor: spendPalette.time,
                spark: vm.spendSeries,
                resetsAt: UsageMath.monthResetDate(now: now),
                sparkTooltip: UsageMath.recentPeakText(vm.spendSeries, unit: .dollars)))
        }
        return out
    }

    /// Compose the circles into one status-item image.
    static func trayImage(from vm: TrayViewModel, now: Date = Date()) -> NSImage {
        image(circles: circles(from: vm, now: now))
    }

    static func image(circles: [Circle]) -> NSImage {
        // With nothing enabled/fetched, draw a single empty ring so the item stays visible.
        let drawn = circles.isEmpty
            ? [Circle(kind: .pie(time: 0, usage: 0), caption: "", usageColor: spendPalette.usage, timeColor: spendPalette.time)]
            : circles
        let size = size(circles: drawn.count)
        let image = NSImage(size: size, flipped: false) { _ in
            let y = (size.height - diameter) / 2
            for (i, c) in drawn.enumerated() {
                let rect = NSRect(x: CGFloat(i) * (diameter + gap), y: y, width: diameter, height: diameter)
                // The tray drops the black rim so the tiny pies keep their full size.
                draw(c, in: rect, bordered: false)
            }
            return true
        }
        image.isTemplate = false   // real colors, not a monochrome template
        return image
    }

    /// Draw a single circle (pie or warning glyph). Used by both the tray image and
    /// the dropdown header, keeping them in lockstep. `bordered` draws the black rim
    /// (menu only).
    static func draw(_ circle: Circle, in rect: NSRect, bordered: Bool = true) {
        switch circle.kind {
        case .pie(let time, let usage):
            drawPie(time: time, usage: usage, in: rect, timeColor: circle.timeColor,
                    usageColor: circle.usageColor, bordered: bordered)
        case .error:
            drawErrorIcon(in: rect, color: circle.usageColor)
        }
    }

    /// Draw a warning triangle (failed-fetch indicator) fitted to `rect`, tinted in
    /// the provider's color.
    static func drawErrorIcon(in rect: NSRect, color: NSColor) {
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
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Draw one circle from already-computed fractions. Exposed for previews/tests.
    /// `bordered` leaves a black rim inside the disc (menu only).
    static func drawPie(time: Double, usage: Double, in rect: NSRect,
                        timeColor: NSColor, usageColor: NSColor, bordered: Bool = true) {
        let inset = outlineWidth / 2 + 0.25
        let rOuter = min(rect.width, rect.height) / 2 - inset
        let center = NSPoint(x: rect.midX, y: rect.midY)

        // Black backing disc at the full radius. When bordered, the colored content is
        // drawn inside a thinner radius so the annulus stays black — the pie's rim,
        // which separates it from a pale background in the menu.
        disc.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - rOuter, y: center.y - rOuter,
                                    width: 2 * rOuter, height: 2 * rOuter)).fill()
        let r = bordered ? rOuter - max(borderMinWidth, rOuter * borderRatio) : rOuter

        // Time: a solid wedge spanning the whole radius (both lanes).
        fillWedge(center: center, radius: r, from: 0, to: time, color: timeColor)
        // Usage: a ring in the outer lane, over the time wedge.
        fillRingWedge(center: center, innerRadius: r * ringInnerRatio, outerRadius: r,
                      from: 0, to: usage, color: usageColor)

        strokeOutline(center: center, radius: r)

        // A full ring (window at 100%) gets a small white center dot as a subtle "maxed"
        // flag. Clamped usage means this fires only at an actual ≥100%.
        if usage >= 1 {
            let dotR = r * fullDotRatio
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - dotR, y: center.y - dotR,
                                        width: 2 * dotR, height: 2 * dotR)).fill()
        }
    }

    private static func strokeOutline(center: NSPoint, radius r: CGFloat) {
        outline.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = outlineWidth
        ring.stroke()
    }

    /// Point on the circle of radius `r` about `center` at fraction `f`, measured
    /// clockwise from 12 o'clock.
    private static func arcPoint(center: NSPoint, radius r: CGFloat, fraction f: Double) -> NSPoint {
        let angle = (90.0 - f * 360.0) * .pi / 180.0
        return NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }

    /// Fill a pie wedge spanning fractions [a, b], measured clockwise from 12 o'clock.
    private static func fillWedge(center: NSPoint, radius r: CGFloat,
                                  from a: Double, to b: Double, color: NSColor) {
        guard b > a, r > 0 else { return }
        let path = NSBezierPath()
        path.move(to: center)
        let steps = max(2, Int((b - a) * 360))
        for i in 0...steps {
            path.line(to: arcPoint(center: center, radius: r, fraction: a + (b - a) * Double(i) / Double(steps)))
        }
        path.close()
        color.setFill()
        path.fill()
    }

    /// Fill an annular (ring) wedge spanning fractions [a, b] between `innerR` and
    /// `outerR`, clockwise from 12 o'clock.
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
