import Foundation

/// Pure geometry/formatting for the usage windows. Kept free of AppKit so it's
/// unit-testable and the pie renderer and menu text share one source of truth.
///
/// The two pie layers, both drawn from 12 o'clock clockwise:
///   • time layer  — fraction of the window that has elapsed (0 at window start,
///                    → 1 just before reset).
///   • usage layer  — utilization / 100.
/// Where they overlap is yellow; the surplus beyond the overlap is blue when more
/// time than usage has elapsed (under pace) or red when usage leads (over pace).
enum UsageMath {
    /// Fraction of `window` that has elapsed for a bucket, clamped to 0…1.
    /// Derived from the reset time exactly as SpaceTerm does:
    /// elapsed = window − (resetsAt − now).
    static func timeFraction(resetsAt: Date, window: TimeInterval, now: Date = Date()) -> Double {
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = window - remaining
        return clamp01(elapsed / window)
    }

    /// Usage layer fraction (utilization is a 0…100 percentage), clamped to 0…1
    /// for drawing. The raw utilization is used for text so it can read ≥100.
    static func usageFraction(utilization: Double) -> Double {
        clamp01(utilization / 100)
    }

    /// Minimum elapsed time before we show a projection (avoids wild early swings).
    static let projectionMinElapsed: TimeInterval = 10 * 60

    /// Linear extrapolation of end-of-window utilization, or nil when there isn't
    /// enough signal yet (too early, no usage, or window already expired). Can
    /// exceed 100 — that's the useful part of the warning. Matches SpaceTerm's
    /// `projectUsage`: utilization × window / elapsed.
    static func projectUsage(utilization: Double, resetsAt: Date, window: TimeInterval,
                             now: Date = Date()) -> Double? {
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return nil }
        let elapsed = window - remaining
        if elapsed < projectionMinElapsed { return nil }
        if utilization <= 0 { return nil }
        return utilization * (window / elapsed)
    }

    /// The two arc boundaries and the surplus color, as fractions of the circle
    /// measured clockwise from 12 o'clock.
    struct Segments: Equatable {
        /// 0 → yellowEnd is the overlap (yellow).
        var yellowEnd: Double
        /// yellowEnd → surplusEnd is the surplus (blue or red); empty when equal.
        var surplusEnd: Double
        /// True = time leads (blue, under pace); false = usage leads (red, over pace).
        var timeLeads: Bool
    }

    static func segments(time: Double, usage: Double) -> Segments {
        let t = clamp01(time), u = clamp01(usage)
        return Segments(yellowEnd: min(t, u), surplusEnd: max(t, u), timeLeads: t >= u)
    }

    // MARK: - Text formatting

    /// Reset time rounded to the nearest minute (the API gives second resolution;
    /// rounding to the hour was off by up to ~30 min). Includes the date when the
    /// reset is not today. e.g. "3:30 PM" or "Jul 19, 4:00 PM".
    static func formatResetTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let rounded = Date(timeIntervalSince1970:
            (date.timeIntervalSince1970 / 60).rounded() * 60)
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let time = timeFmt.string(from: rounded)
        if calendar.isDate(rounded, inSameDayAs: now) { return time }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d"
        return "\(dateFmt.string(from: rounded)), \(time)"
    }

    /// Human "time until reset", e.g. "48m", "2h 5m", "1d 2h", "now". Above a day
    /// we show days + hours (the 7-day window would otherwise read like "25h 50m").
    static func formatDelta(to date: Date, now: Date = Date()) -> String {
        let diff = date.timeIntervalSince(now)
        if diff <= 0 { return "now" }
        let totalMinutes = Int((diff / 60).rounded(.up))
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            return minutes > 0 ? "\(totalHours)h \(minutes)m" : "\(totalHours)h"
        }
        let days = totalHours / 24, hours = totalHours % 24
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }

    /// Fill fraction (0…1) for the spend circle. Prefers a user-set custom limit,
    /// then the API-supplied limit, then the API's own utilization percentage.
    static func spendFraction(_ e: ExtraUsage, customLimitCents: Double? = nil) -> Double {
        if let custom = customLimitCents, custom > 0 { return clamp01(e.usedCents / custom) }
        if let limit = e.monthlyLimitCents, limit > 0 { return clamp01(e.usedCents / limit) }
        return clamp01(e.utilization / 100)
    }

    /// Highest per-minute consumption rate across a cumulative series, and when it
    /// occurred. Each interval's rate is the (non-negative) rise divided by the
    /// actual minutes between those two samples — so it's correct even if sampling
    /// isn't exactly every 5 minutes. Returns nil if there was no positive usage.
    static func peakRatePerMinute(_ points: [(Date, Double)]) -> (perMinute: Double, at: Date)? {
        guard points.count >= 2 else { return nil }
        var best: (perMinute: Double, at: Date)?
        for i in 1..<points.count {
            let minutes = points[i].0.timeIntervalSince(points[i - 1].0) / 60
            guard minutes > 0 else { continue }
            let rate = max(0, points[i].1 - points[i - 1].1) / minutes
            if rate > 0, best == nil || rate > best!.perMinute {
                best = (rate, points[i].0)
            }
        }
        return best
    }

    /// A number with trailing-zero-trimmed decimals (e.g. 0.5000121 → "0.5",
    /// 1.0 → "1", 0.333… → "0.33"). Keeps rate readouts from looking like noise.
    static func trimmed(_ value: Double, maxFractionDigits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxFractionDigits
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Convert a cumulative series (utilization %, or spend cents) into a per-slot
    /// *rate* series for the sparklines: each point is how much was consumed since
    /// the previous sample. The first point is 0 (no prior to compare), and drops
    /// (window resets, or spend rollover) clamp to 0 — so the line sits near zero
    /// during quiet periods and spikes when usage bursts.
    static func usageRateSeries(_ cumulative: [Double]) -> [Double] {
        guard !cumulative.isEmpty else { return [] }
        var out: [Double] = [0]
        for i in 1..<cumulative.count { out.append(max(0, cumulative[i] - cumulative[i - 1])) }
        return out
    }

    /// Fraction of the current calendar month that has elapsed (the spend "time"
    /// layer — spend limits reset monthly). Clamped to 0…1.
    static func monthTimeFraction(now: Date = Date(), calendar: Calendar = .current) -> Double {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return 0 }
        let total = nextMonth.timeIntervalSince(monthStart)
        guard total > 0 else { return 0 }
        return clamp01(now.timeIntervalSince(monthStart) / total)
    }

    /// Cents → "$42.50".
    static func formatDollars(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }

    /// Wall-clock time only, e.g. "12:15 PM".
    static func formatClockTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// Compact lowercased time, e.g. "1:00pm" (for the recent-peak readout).
    static func formatClockCompact(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mma"
        return f.string(from: date).lowercased()
    }

    /// "just now", "2m ago", "1h 5m ago", "1d 2h ago".
    static func formatAgo(since date: Date, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 45 { return "just now" }
        let totalMinutes = Int((diff / 60).rounded())
        if totalMinutes < 1 { return "just now" }
        if totalMinutes < 60 { return "\(totalMinutes)m ago" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            return minutes > 0 ? "\(totalHours)h \(minutes)m ago" : "\(totalHours)h ago"
        }
        let days = totalHours / 24, hours = totalHours % 24
        return hours > 0 ? "\(days)d \(hours)h ago" : "\(days)d ago"
    }

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}
