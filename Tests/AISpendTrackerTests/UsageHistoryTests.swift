import XCTest
@testable import AISpendTracker

@MainActor
final class UsageHistoryTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cut-history-test-\(UUID().uuidString).jsonl")
    }

    private func snap(five: Double, seven: Double, spend: Double) -> ProviderSnapshot {
        ProviderSnapshot(windows: [
            UsageWindow(caption: "5-Hour", utilization: five, resetsAt: Date(),
                        timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
            UsageWindow(caption: "7-Day", utilization: seven, resetsAt: Date(),
                        timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
        ], spend: SpendInfo(usedCents: spend, apiLimitCents: 50000, label: "Claude extra usage"))
    }

    func testRecentWindowFiltersToDisplayWindow() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let h = UsageHistory(fileURL: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        h.record(snap(five: 10, seven: 10, spend: 100), now: now.addingTimeInterval(-3 * 3600))
        h.record(snap(five: 20, seven: 20, spend: 100), now: now.addingTimeInterval(-90 * 60))
        h.record(snap(five: 30, seven: 30, spend: 100), now: now.addingTimeInterval(-10 * 60))
        XCTAssertEqual(h.recent(window: 2 * 3600, now: now).count, 2)
        XCTAssertEqual(h.recent(window: 30 * 24 * 3600, now: now).count, 3)
    }

    func testPrunesBeyondRetention() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let h = UsageHistory(fileURL: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        h.record(snap(five: 1, seven: 1, spend: 1), now: now.addingTimeInterval(-40 * 24 * 3600))
        h.record(snap(five: 2, seven: 2, spend: 2), now: now.addingTimeInterval(-5 * 24 * 3600))
        h.record(snap(five: 3, seven: 3, spend: 3), now: now)
        XCTAssertEqual(h.samples.count, 2)
        XCTAssertEqual(h.samples.first?.windows["5-Hour"], 2)
    }

    func testPersistsAcrossInstances() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        do {
            let h = UsageHistory(fileURL: url)
            h.record(snap(five: 42, seven: 55, spend: 24955), now: now.addingTimeInterval(-30 * 60))
        }
        let reopened = UsageHistory(fileURL: url)
        let samples = reopened.recent(window: 2 * 3600, now: now)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.spendCents, 24955)
        XCTAssertEqual(samples.first?.windows["7-Day"], 55)
    }
}
