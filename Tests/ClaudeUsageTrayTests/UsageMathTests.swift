import XCTest
@testable import ClaudeUsageTray

final class UsageMathTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testTimeFractionMidWindow() {
        // 2h remaining in a 5h window → 3h elapsed → 60%.
        let resets = now.addingTimeInterval(2 * 3600)
        let f = UsageMath.timeFraction(resetsAt: resets, window: UsageWindow.fiveHour, now: now)
        XCTAssertEqual(f, 0.6, accuracy: 1e-9)
    }

    func testTimeFractionClampsBothEnds() {
        // Reset already passed → clamp to 1.
        XCTAssertEqual(UsageMath.timeFraction(resetsAt: now.addingTimeInterval(-60),
                                              window: UsageWindow.fiveHour, now: now), 1)
        // Reset a full window+ away → clamp to 0.
        XCTAssertEqual(UsageMath.timeFraction(resetsAt: now.addingTimeInterval(UsageWindow.fiveHour + 60),
                                              window: UsageWindow.fiveHour, now: now), 0)
    }

    func testUsageFractionClamps() {
        XCTAssertEqual(UsageMath.usageFraction(utilization: 45), 0.45, accuracy: 1e-9)
        XCTAssertEqual(UsageMath.usageFraction(utilization: 130), 1)
        XCTAssertEqual(UsageMath.usageFraction(utilization: -5), 0)
    }

    func testProjectionExtrapolatesLinearly() {
        // 60% elapsed, 45% used → projected 45 / 0.6 = 75%.
        let resets = now.addingTimeInterval(2 * 3600)
        let proj = UsageMath.projectUsage(utilization: 45, resetsAt: resets,
                                          window: UsageWindow.fiveHour, now: now)
        XCTAssertNotNil(proj)
        XCTAssertEqual(proj!, 75, accuracy: 1e-6)
    }

    func testProjectionCanExceed100() {
        // 28.6% elapsed, 50% used → ~175%.
        let resets = now.addingTimeInterval(5 * 24 * 3600)
        let proj = UsageMath.projectUsage(utilization: 50, resetsAt: resets,
                                          window: UsageWindow.sevenDay, now: now)
        XCTAssertNotNil(proj)
        XCTAssertGreaterThan(proj!, 100)
    }

    func testProjectionNilWhenTooEarly() {
        // Only 5 min elapsed (< 10 min threshold).
        let resets = now.addingTimeInterval(UsageWindow.fiveHour - 5 * 60)
        XCTAssertNil(UsageMath.projectUsage(utilization: 5, resetsAt: resets,
                                            window: UsageWindow.fiveHour, now: now))
    }

    func testProjectionNilWhenExpiredOrZero() {
        XCTAssertNil(UsageMath.projectUsage(utilization: 40, resetsAt: now.addingTimeInterval(-1),
                                            window: UsageWindow.fiveHour, now: now))
        let resets = now.addingTimeInterval(2 * 3600)
        XCTAssertNil(UsageMath.projectUsage(utilization: 0, resetsAt: resets,
                                            window: UsageWindow.fiveHour, now: now))
    }

    func testMonthTimeFraction() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // July has 31 days; midnight on the 16th → 15 full days elapsed.
        let midJuly = cal.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 0))!
        XCTAssertEqual(UsageMath.monthTimeFraction(now: midJuly, calendar: cal), 15.0 / 31.0, accuracy: 1e-9)
        // First instant of the month → 0.
        let start = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 0))!
        XCTAssertEqual(UsageMath.monthTimeFraction(now: start, calendar: cal), 0, accuracy: 1e-9)
    }

    func testSpendFractionUsesCustomThenAPILimit() {
        let e = ExtraUsage(isEnabled: true, usedCents: 24955, monthlyLimitCents: 50000, utilization: 99)
        XCTAssertEqual(UsageMath.spendFraction(e), 0.4991, accuracy: 1e-9)                     // used/API-limit
        XCTAssertEqual(UsageMath.spendFraction(e, customLimitCents: 100000), 0.24955, accuracy: 1e-9) // custom wins
        // No limit at all → 0 (and the donut is hidden; see showsSpendCircle).
        let noLimit = ExtraUsage(isEnabled: true, usedCents: 24955, monthlyLimitCents: nil, utilization: 30)
        XCTAssertEqual(UsageMath.spendFraction(noLimit), 0)
    }

    func testSegmentsBlueWhenTimeLeads() {
        let seg = UsageMath.segments(time: 0.6, usage: 0.45)
        XCTAssertEqual(seg.yellowEnd, 0.45, accuracy: 1e-9)
        XCTAssertEqual(seg.surplusEnd, 0.6, accuracy: 1e-9)
        XCTAssertTrue(seg.timeLeads)   // → blue
    }

    func testSegmentsRedWhenUsageLeads() {
        let seg = UsageMath.segments(time: 0.3, usage: 0.5)
        XCTAssertEqual(seg.yellowEnd, 0.3, accuracy: 1e-9)
        XCTAssertEqual(seg.surplusEnd, 0.5, accuracy: 1e-9)
        XCTAssertFalse(seg.timeLeads)  // → red
    }

    func testUsageRateSeriesClampsResets() {
        // Cumulative climbs then resets; rate is per-slot rise, first point 0,
        // the reset drop clamps to 0.
        let rates = UsageMath.usageRateSeries([10, 12, 20, 5, 9])
        XCTAssertEqual(rates, [0, 2, 8, 0, 4])
    }

    func testPeakRatePerMinute() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let points: [(Date, Double)] = [
            (t, 10),
            (t.addingTimeInterval(5 * 60), 11),    // +1 over 5 min = 0.2/min
            (t.addingTimeInterval(10 * 60), 14),   // +3 over 5 min = 0.6/min  ← peak
            (t.addingTimeInterval(15 * 60), 2),    // reset → clamped to 0
        ]
        let peak = UsageMath.peakRatePerMinute(points)
        XCTAssertNotNil(peak)
        XCTAssertEqual(peak!.perMinute, 0.6, accuracy: 1e-9)
        XCTAssertEqual(peak!.at, t.addingTimeInterval(10 * 60))
    }

    func testPeakRateNilWhenNoUsage() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        // Flat then a reset — no positive rate anywhere.
        XCTAssertNil(UsageMath.peakRatePerMinute([(t, 5), (t.addingTimeInterval(300), 5),
                                                  (t.addingTimeInterval(600), 0)]))
    }

    func testTrimmed() {
        XCTAssertEqual(UsageMath.trimmed(0.5000121, maxFractionDigits: 2), "0.5")
        XCTAssertEqual(UsageMath.trimmed(1.0, maxFractionDigits: 2), "1")
        XCTAssertEqual(UsageMath.trimmed(0.333333, maxFractionDigits: 2), "0.33")
    }

    func testFormatDelta() {
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(48 * 60), now: now), "48m")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now), "2h 5m")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(3 * 3600), now: now), "3h")
        // Above a day → days + hours (25h50m → 25h floored → 1d 1h).
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(25 * 3600 + 50 * 60), now: now), "1d 1h")
        XCTAssertEqual(UsageMath.formatDelta(to: now.addingTimeInterval(48 * 3600), now: now), "2d")
    }
}
