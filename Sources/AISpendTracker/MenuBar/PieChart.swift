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

    /// Claude's per-model scoped windows (e.g. "Fable 7-Day") render golden-amber so
    /// they read as distinct from the primary 5-hour/7-day windows, which keep Claude's
    /// orange. #E0A82E — a warm, saturated gold that sits harmoniously beside the brand
    /// colors; its 60%-dimmed time wedge lands on a rich bronze rather than muddy olive.
    static let scopedPalette = make(224, 168, 46)

    private static func make(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Palette {
        Palette(usage: NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1),
                time: NSColor(srgbRed: r / 255 * 0.6, green: g / 255 * 0.6, blue: b / 255 * 0.6, alpha: 1))
    }

    // Untouched remainder — black.
    static let disc = NSColor.black
    // Subtle hairline ring rather than a bold white edge. The default suits a dark
    // backdrop (the menu header, and the menu bar in dark mode); the tray passes a
    // dark hairline in light mode via `outline(forDark:)`.
    static let outline = NSColor(white: 1, alpha: 0.5)

    /// Hairline color for a given backdrop: white on dark, black on light — a faint
    /// separator either way. The tray picks this from the menu bar's appearance.
    static func outline(forDark isDark: Bool) -> NSColor {
        NSColor(white: isDark ? 1 : 0, alpha: 0.5)
    }
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
        /// The provider's last raw response body, or nil for the combined spend circle
        /// (and providers that haven't recorded one). Header-only: makes the column's
        /// "Updated" row copyable. Unused by the tray image.
        var rawResponse: String?
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
        /// When this circle's provider last fetched successfully — drives the header
        /// column's live "Updated: …" line. For the spend circle it's the newest fetch
        /// across providers. Header-only.
        var lastUpdated: Date?
        /// Hover text for the pie (projected end-of-window usage) and the sparkline
        /// (recent peak rate), or nil when there isn't enough signal. Header-only.
        var pieTooltip: String?
        var sparkTooltip: String?

        init(kind: Kind, rawResponse: String? = nil, heading: String? = nil, caption: String,
             usageColor: NSColor, timeColor: NSColor, spark: [(Date, Double)] = [],
             resetsAt: Date? = nil, lastUpdated: Date? = nil,
             pieTooltip: String? = nil, sparkTooltip: String? = nil) {
            self.kind = kind
            self.rawResponse = rawResponse
            self.heading = heading
            self.caption = caption
            self.usageColor = usageColor
            self.timeColor = timeColor
            self.spark = spark
            self.resetsAt = resetsAt
            self.lastUpdated = lastUpdated
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
    ///
    /// `includeSpend` gates the trailing spend pie: the tray drops it in text/off
    /// display mode (the figure is drawn as the button title instead, or hidden),
    /// while the dropdown header always passes `true` to keep the rich spend column.
    static func circles(from vm: TrayViewModel, now: Date = Date(), includeSpend: Bool = true) -> [Circle] {
        var out: [Circle] = []
        for p in vm.providers {
            let pal = palette(for: p.id)
            if p.error != nil {
                out.append(Circle(kind: .error, rawResponse: p.lastRawResponse,
                                  heading: p.displayName, caption: "unavailable",
                                  usageColor: pal.usage, timeColor: pal.time, lastUpdated: p.lastUpdated))
            } else if let snap = p.snapshot {
                let at = p.lastUpdated ?? now
                for w in snap.windows {
                    let series = p.series(forWindow: w.caption)
                    let wpal = w.isScoped ? scopedPalette : pal
                    out.append(Circle(
                        kind: .pie(time: UsageMath.timeFraction(w.timeBasis, resetsAt: w.resetsAt, now: at),
                                   usage: UsageMath.usageFraction(utilization: w.utilization)),
                        rawResponse: p.lastRawResponse, heading: p.displayName, caption: w.caption,
                        usageColor: wpal.usage, timeColor: wpal.time,
                        spark: series,
                        resetsAt: w.resetsAt,
                        lastUpdated: p.lastUpdated,
                        pieTooltip: UsageMath.projectedText(w, now: at),
                        sparkTooltip: UsageMath.recentPeakText(series, unit: .percent)))
                }
            }
        }
        if includeSpend && vm.hasAnySpend {
            out.append(Circle(
                kind: .pie(time: UsageMath.monthTimeFraction(now: vm.latestUpdate ?? now),
                           usage: UsageMath.spendFraction(usedCents: vm.combinedSpendCents,
                                                          limitCents: vm.customLimitCents)),
                heading: UsageMath.formatDollars(vm.combinedSpendCents), caption: "Spend",
                usageColor: spendPalette.usage, timeColor: spendPalette.time,
                spark: vm.spendSeries,
                resetsAt: UsageMath.monthResetDate(now: now),
                lastUpdated: vm.latestUpdate,
                sparkTooltip: UsageMath.recentPeakText(vm.spendSeries, unit: .dollars)))
        }
        return out
    }

    /// Compose the circles into one status-item image. `outline` is the hairline color
    /// for the current menu-bar appearance (white on dark, black on light).
    static func trayImage(from vm: TrayViewModel, now: Date = Date(), outline: NSColor = Self.outline) -> NSImage {
        image(circles: circles(from: vm, now: now), outline: outline)
    }

    static func image(circles: [Circle], outline: NSColor = Self.outline) -> NSImage {
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
                draw(c, in: rect, bordered: false, outline: outline)
            }
            return true
        }
        image.isTemplate = false   // real colors, not a monochrome template
        return image
    }

    /// Draw a single circle (pie or warning glyph). Used by both the tray image and
    /// the dropdown header, keeping them in lockstep. `bordered` draws the black rim
    /// (menu only); `outline` is the hairline color.
    static func draw(_ circle: Circle, in rect: NSRect, bordered: Bool = true, outline: NSColor = Self.outline) {
        switch circle.kind {
        case .pie(let time, let usage):
            drawPie(time: time, usage: usage, in: rect, timeColor: circle.timeColor,
                    usageColor: circle.usageColor, bordered: bordered, outline: outline)
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
                        timeColor: NSColor, usageColor: NSColor, bordered: Bool = true,
                        outline: NSColor = Self.outline) {
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
        // Usage: a ring in the outer lane, over the time wedge. Clamped to one full turn
        // so an over-100% reading (shown in the text) never overfills the pie.
        fillRingWedge(center: center, innerRadius: r * ringInnerRatio, outerRadius: r,
                      from: 0, to: min(1, max(0, usage)), color: usageColor)

        strokeOutline(center: center, radius: r, color: outline)

        // At ≥100% the ring is full; add a small white center dot as a subtle "maxed"
        // flag. Applies to every pie, spend included.
        if usage >= 1 {
            let dotR = r * fullDotRatio
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - dotR, y: center.y - dotR,
                                        width: 2 * dotR, height: 2 * dotR)).fill()
        }
    }

    private static func strokeOutline(center: NSPoint, radius r: CGFloat, color: NSColor = outline) {
        color.setStroke()
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
