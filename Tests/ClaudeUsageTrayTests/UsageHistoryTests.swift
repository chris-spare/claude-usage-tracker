import XCTest
@testable import ClaudeUsageTray

@MainActor
final class UsageHistoryTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cut-history-test-\(UUID().uuidString).jsonl")
    }

    private func data(five: Double, seven: Double, spend: Double) -> ClaudeUsageData {
        ClaudeUsageData(
            fiveHour: UsageBucket(utilization: five, resetsAt: Date()),
            sevenDay: UsageBucket(utilization: seven, resetsAt: Date()),
            extraUsage: ExtraUsage(isEnabled: true, usedCents: spend, monthlyLimitCents: 50000, utilization: 0))
    }

    func testRecentWindowFiltersToDisplayWindow() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let h = UsageHistory(retention: 30 * 24 * 3600, fileURL: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        h.record(data(five: 10, seven: 10, spend: 100), now: now.addingTimeInterval(-3 * 3600)) // 3h ago
        h.record(data(five: 20, seven: 20, spend: 100), now: now.addingTimeInterval(-90 * 60))  // 90m ago
        h.record(data(five: 30, seven: 30, spend: 100), now: now.addingTimeInterval(-10 * 60))  // 10m ago
        // 2h window keeps only the last two; 30-day retention keeps all three.
        XCTAssertEqual(h.recent(window: 2 * 3600, now: now).count, 2)
        XCTAssertEqual(h.recent(window: 30 * 24 * 3600, now: now).count, 3)
    }

    func testPrunesBeyondRetention() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let h = UsageHistory(retention: 30 * 24 * 3600, fileURL: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        h.record(data(five: 1, seven: 1, spend: 1), now: now.addingTimeInterval(-40 * 24 * 3600)) // 40d ago
        h.record(data(five: 2, seven: 2, spend: 2), now: now.addingTimeInterval(-5 * 24 * 3600))  // 5d ago
        h.record(data(five: 3, seven: 3, spend: 3), now: now)                                       // triggers prune
        // The 40-day-old sample is dropped (past retention + slack); the rest remain.
        XCTAssertEqual(h.samples.count, 2)
        XCTAssertEqual(h.samples.first?.fiveHourUtil, 2)
    }

    func testPersistsAcrossInstances() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        do {
            let h = UsageHistory(retention: 30 * 24 * 3600, fileURL: url)
            h.record(data(five: 42, seven: 55, spend: 24955), now: now.addingTimeInterval(-30 * 60))
        }
        // A fresh instance reads the JSONL back.
        let reopened = UsageHistory(retention: 30 * 24 * 3600, fileURL: url)
        let samples = reopened.recent(window: 2 * 3600, now: now)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.spendCents, 24955)
    }
}
