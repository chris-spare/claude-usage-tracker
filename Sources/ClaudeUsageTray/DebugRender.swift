import AppKit

/// Dev-only: `ClaudeUsageTray --render <out.png>` draws a grid of pie scenarios at
/// large scale (so the arcs are eyeball-verifiable) plus a menu-bar-size preview,
/// writes a PNG, and exits. Not used by the running app.
enum DebugRender {
    /// (title, time fraction, usage fraction)
    private static let cases: [(String, Double, Double)] = [
        ("empty (t0 u0)", 0.0, 0.0),
        ("time leads usage", 0.60, 0.45),
        ("usage leads time", 0.30, 0.50),
        ("equal", 0.50, 0.50),
        ("usage over 100%", 0.30, 1.0),
        ("nearly full time", 0.95, 0.80),
        ("tiny sliver time", 0.03, 0.0),
        ("full both", 1.0, 1.0),
    ]

    static func run(outPath: String) {
        let cell: CGFloat = 160
        let pieD: CGFloat = 120
        let labelH: CGFloat = 24
        let cols = 4
        let rows = (cases.count + cols - 1) / cols
        let width = CGFloat(cols) * cell + 140   // extra room for the error-tray preview
        let height = CGFloat(rows) * (cell + labelH) + 80

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(white: 0.15, alpha: 1).setFill()
            rect.fill()

            for (i, c) in cases.enumerated() {
                let col = i % cols, row = i / cols
                let x = CGFloat(col) * cell
                let y = height - 80 - CGFloat(row + 1) * (cell + labelH) + labelH
                let pieRect = NSRect(x: x + (cell - pieD) / 2, y: y, width: pieD, height: pieD)
                PieChart.drawPie(time: c.1, usage: c.2, in: pieRect)
                drawLabel(c.0, centeredIn: NSRect(x: x, y: y - labelH, width: cell, height: labelH))
            }

            // Draw the actual tray image scaled up so we see the true menu-bar look.
            let tray = PieChart.trayImage(fiveHour: UsageBucket(utilization: 72, resetsAt: Date().addingTimeInterval(2 * 3600)),
                                          sevenDay: UsageBucket(utilization: 40, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
                                          extraUsage: ExtraUsage(isEnabled: true, usedCents: 12345,
                                                                 monthlyLimitCents: 50000, utilization: 24.69))
            let scale: CGFloat = 5
            let tw = tray.size.width * scale, th = tray.size.height * scale
            tray.draw(in: NSRect(x: 20, y: 20, width: tw, height: th),
                      from: .zero, operation: .sourceOver, fraction: 1)
            drawLabel("actual tray image ×5", centeredIn: NSRect(x: 20, y: 20 + th, width: tw, height: 20))

            // Error-state tray (custom limit + warning glyph).
            let errTray = PieChart.trayImage(
                fiveHour: UsageBucket(utilization: 72, resetsAt: Date().addingTimeInterval(2 * 3600)),
                sevenDay: UsageBucket(utilization: 40, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
                extraUsage: ExtraUsage(isEnabled: true, usedCents: 12345, monthlyLimitCents: 50000, utilization: 24.69),
                customLimitCents: 30000, showError: true)
            let ew = errTray.size.width * scale, eh = errTray.size.height * scale
            let ex = 20 + tw + 40
            errTray.draw(in: NSRect(x: ex, y: 20, width: ew, height: eh),
                         from: .zero, operation: .sourceOver, fraction: 1)
            drawLabel("error + custom limit ×5", centeredIn: NSRect(x: ex, y: 20 + eh, width: ew, height: 20))

            // Sparkline preview over a fixed 2-hour axis ending "now": an older
            // cluster, a gap (missed samples → broken line), then a recent cluster
            // ending at the right edge. Empty stretches stay empty (not stretched).
            let now = Date()
            func t(_ minAgo: Double) -> Date { now.addingTimeInterval(-minAgo * 60) }
            let samples: [(Date, Double)] = [
                (t(90), 10), (t(85), 12), (t(80), 20), (t(75), 24),          // older cluster
                (t(25), 30), (t(20), 46), (t(15), 50), (t(10), 51), (t(5), 70), (t(0), 78), // recent, after a gap
            ]
            let sparkRect = NSRect(x: 40, y: height - 56, width: 260, height: 36)
            Sparkline.draw(points: UsageMath.usageRatePoints(samples),
                           window: 2 * 60 * 60, now: now,
                           in: sparkRect, color: .white, gapThreshold: 8 * 60, leftInset: 6, rightInset: 6)
            drawLabel("usage-rate sparkline (fixed 2h axis, gaps left blank)",
                      centeredIn: NSRect(x: 40, y: height - 78, width: 360, height: 20))
            return true
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render: failed to encode PNG\n".utf8)); return
        }
        try? png.write(to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write(Data("render: wrote \(outPath)\n".utf8))
    }

    private static func drawLabel(_ text: String, centeredIn rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}
