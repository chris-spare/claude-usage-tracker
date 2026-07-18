import XCTest
@testable import AIUsageTracker

final class ClaudeUsageFetcherTests: XCTestCase {
    private func window(_ snap: ProviderSnapshot, _ caption: String) -> UsageWindow? {
        snap.windows.first { $0.caption == caption }
    }

    /// A fresh/idle 5-hour window comes back with null utilization + resets_at. It
    /// must render as 0% usage / 0% time (window not started), not "no data" and not
    /// a decode failure.
    func testNullFiveHourWindowReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": null, "resets_at": null },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" },
          "extra_usage": { "is_enabled": true, "used_credits": 12345, "monthly_limit": 50000, "utilization": 24.69 }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let five = try XCTUnwrap(window(snap, "5-Hour"))
        XCTAssertEqual(five.utilization, 0)                                     // 0% usage
        XCTAssertNil(five.resetsAt)                                             // no reset yet …
        XCTAssertEqual(UsageMath.timeFraction(five.timeBasis, resetsAt: five.resetsAt, now: Date()), 0) // → 0% time
        XCTAssertEqual(window(snap, "7-Day")?.utilization, 63)                  // others still parse
    }

    /// Same for a null 7-day window.
    func testNullSevenDayWindowReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": null, "resets_at": null }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let seven = try XCTUnwrap(window(snap, "7-Day"))
        XCTAssertEqual(seven.utilization, 0)
        XCTAssertNil(seven.resetsAt)
        XCTAssertEqual(UsageMath.timeFraction(seven.timeBasis, resetsAt: seven.resetsAt, now: Date()), 0)
    }

    /// Null spend fields read as $0.
    func testNullSpendReadsAsZero() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" },
          "extra_usage": { "is_enabled": true, "used_credits": null, "monthly_limit": 50000, "utilization": null }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.usedCents, 0)
        XCTAssertEqual(spend.apiLimitCents, 50000)
        XCTAssertEqual(UsageMath.spendFraction(usedCents: spend.usedCents, limitCents: 50000), 0)
    }

    /// Spend maps used_credits → cents and monthly_limit → apiLimitCents.
    func testSpendDecodes() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" },
          "extra_usage": { "is_enabled": true, "used_credits": 12345, "monthly_limit": 50000, "utilization": 24.69 }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertEqual(snap.spend?.usedCents, 12345)
        XCTAssertEqual(snap.spend?.apiLimitCents, 50000)
        XCTAssertEqual(snap.spend?.label, "Claude extra usage")
    }

    /// Missing extra_usage → no spend contribution.
    func testMissingSpendIsNil() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" }
        }
        """
        XCTAssertNil(try ClaudeUsageFetcher.decode(Data(json.utf8)).spend)
    }

    func testDecodeFractionalAndPlainTimestamps() throws {
        let json = """
        {
          "five_hour": { "utilization": 40, "resets_at": "2026-07-15T18:30:00.123Z" },
          "seven_day": { "utilization": 63, "resets_at": "2026-07-16T14:00:00Z" }
        }
        """
        let snap = try ClaudeUsageFetcher.decode(Data(json.utf8))
        XCTAssertNotNil(window(snap, "5-Hour")?.resetsAt)
        XCTAssertNotNil(window(snap, "7-Day")?.resetsAt)
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

    /// Error taxonomy: no credentials is permanent, transient failures are not.
    func testClassify() {
        let f = ClaudeUsageFetcher()
        XCTAssertTrue(f.classify(ClaudeUsageFetcher.NoOAuthCredentialsError()).permanent)
        XCTAssertFalse(f.classify(ClaudeUsageFetcher.KeychainError(detail: "locked")).permanent)
        XCTAssertFalse(f.classify(ClaudeUsageFetcher.UsageAPIError(status: 500, body: "")).permanent)
    }
}
