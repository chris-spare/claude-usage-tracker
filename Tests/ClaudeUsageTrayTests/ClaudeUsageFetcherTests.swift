import XCTest
@testable import ClaudeUsageTray

final class ClaudeUsageFetcherTests: XCTestCase {
    /// A fresh/idle 5-hour window comes back with null utilization + resets_at. It
    /// must render as 0% usage / 0% time (window not started), not "no data" and not
    /// a decode failure. (Regression: previously threw a DecodingError.)
    func testNullFiveHourWindowReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": null, "resets_at": null },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" },
          "extra_usage": { "is_enabled": true, "used_credits": 12345, "monthly_limit": 50000, "utilization": 24.69 }
        }
        """
        let usage = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let five = try XCTUnwrap(usage.fiveHour)
        XCTAssertEqual(five.utilization, 0)               // 0% usage
        XCTAssertNil(five.resetsAt)                        // no reset yet …
        XCTAssertEqual(UsageMath.timeFraction(resetsAt: five.resetsAt, window: UsageWindow.fiveHour), 0) // … → 0% time
        XCTAssertEqual(usage.sevenDay?.utilization, 63)    // others still parse
    }

    /// Same for a null 7-day window.
    func testNullSevenDayWindowReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": null, "resets_at": null }
        }
        """
        let usage = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let seven = try XCTUnwrap(usage.sevenDay)
        XCTAssertEqual(seven.utilization, 0)
        XCTAssertNil(seven.resetsAt)
        XCTAssertEqual(UsageMath.timeFraction(resetsAt: seven.resetsAt, window: UsageWindow.sevenDay), 0)
    }

    /// Null spend fields read as $0 (0%), against a present limit.
    func testNullSpendReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" },
          "extra_usage": { "is_enabled": true, "used_credits": null, "monthly_limit": 50000, "utilization": null }
        }
        """
        let usage = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let extra = try XCTUnwrap(usage.extraUsage)
        XCTAssertEqual(extra.usedCents, 0)
        XCTAssertEqual(UsageMath.spendFraction(extra), 0)
    }

    /// The spend donut shows only when there's a limit to measure against.
    func testSpendCircleVisibility() {
        let noLimit = ExtraUsage(isEnabled: true, usedCents: 12345, monthlyLimitCents: nil, utilization: 0)
        let apiLimit = ExtraUsage(isEnabled: true, usedCents: 12345, monthlyLimitCents: 50000, utilization: 24.69)
        XCTAssertFalse(UsageMath.showsSpendCircle(nil, customLimitCents: nil))
        XCTAssertFalse(UsageMath.showsSpendCircle(noLimit, customLimitCents: nil))   // no API + no custom → hidden
        XCTAssertTrue(UsageMath.showsSpendCircle(noLimit, customLimitCents: 30000))  // custom limit → shown
        XCTAssertTrue(UsageMath.showsSpendCircle(apiLimit, customLimitCents: nil))   // API limit → shown
    }

    func testDecodeFractionalAndPlainTimestamps() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00.123Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" }
        }
        """
        let usage = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(usage.fiveHour?.utilization, 40)
        XCTAssertEqual(usage.sevenDay?.utilization, 63)
    }

    /// A 401 body should surface the API's own error message, not a raw blob.
    func testAPIErrorUserMessageExtractsMessage() {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"Invalid authentication credentials"},"request_id":"req_x"}"#
        let e = ClaudeUsageFetcher.UsageAPIError(status: 401, body: body)
        XCTAssertEqual(e.userMessage, "Usage API 401: Invalid authentication credentials")
    }

    func testAPIErrorUserMessageFallsBackToTrimmedBody() {
        let e = ClaudeUsageFetcher.UsageAPIError(status: 503, body: "  service unavailable\n")
        XCTAssertEqual(e.userMessage, "Usage API 503: service unavailable")
    }
}
