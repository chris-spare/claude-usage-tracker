import XCTest
@testable import AIUsageTracker

@MainActor
final class UsageStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cut-store-test-\(UUID().uuidString).json")
    }

    /// The old Claude-only cache ({lastFetchAt, data:{fiveHour,sevenDay,extraUsage}})
    /// migrates into the per-provider shape under `.claude`.
    func testMigratesLegacyCache() throws {
        struct LBucket: Codable { var utilization: Double; var resetsAt: Date? }
        struct LExtra: Codable { var isEnabled: Bool; var usedCents: Double; var monthlyLimitCents: Double?; var utilization: Double }
        struct LData: Codable { var fiveHour: LBucket?; var sevenDay: LBucket?; var extraUsage: LExtra? }
        struct LCache: Codable { var lastFetchAt: Date?; var data: LData? }

        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = LCache(lastFetchAt: fetchedAt, data: LData(
            fiveHour: LBucket(utilization: 40, resetsAt: fetchedAt.addingTimeInterval(3600)),
            sevenDay: LBucket(utilization: 63, resetsAt: fetchedAt.addingTimeInterval(86400)),
            extraUsage: LExtra(isEnabled: true, usedCents: 12345, monthlyLimitCents: 50000, utilization: 24.69)))
        try JSONEncoder().encode(legacy).write(to: url)

        let store = UsageStore(fileURL: url)
        XCTAssertEqual(store.lastFetchAt(.claude)?.timeIntervalSinceReferenceDate ?? 0,
                       fetchedAt.timeIntervalSinceReferenceDate, accuracy: 1e-6)
        let snap = try XCTUnwrap(store.snapshot(.claude))
        XCTAssertEqual(snap.windows.map(\.caption), ["5-Hour", "7-Day"])
        XCTAssertEqual(snap.windows[0].utilization, 40)
        XCTAssertEqual(snap.spend?.usedCents, 12345)
        XCTAssertEqual(snap.spend?.apiLimitCents, 50000)
    }

    func testPerProviderRoundTrip() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let store = UsageStore(fileURL: url)
            store.recordAttempt(.codex, at: at)
            store.saveSnapshot(.codex, ProviderSnapshot(windows: [
                UsageWindow(caption: "Weekly", utilization: 30, resetsAt: at,
                            timeBasis: .rollingWindow(length: WindowLength.sevenDay))]))
            // Claude untouched — providers are independent.
            XCTAssertNil(store.snapshot(.claude))
        }
        let reopened = UsageStore(fileURL: url)
        XCTAssertEqual(reopened.lastFetchAt(.codex)?.timeIntervalSinceReferenceDate ?? 0,
                       at.timeIntervalSinceReferenceDate, accuracy: 1e-6)
        XCTAssertEqual(reopened.snapshot(.codex)?.windows.first?.caption, "Weekly")
        XCTAssertNil(reopened.lastFetchAt(.cursor))
    }

    /// The spend total defaults to $2500 when unset.
    func testDefaultSpendTotal() {
        let key = "aiut.customCostTotalCents"   // persistence key kept for back-compat
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Settings.customLimitCents, 250_000)
        Settings.customLimitCents = 300_00
        XCTAssertEqual(Settings.customLimitCents, 30000)
    }

    /// Enabled providers default to Claude only.
    func testDefaultEnabledProviders() {
        let key = "aiut.enabledProviders"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Settings.enabledProviders, [.claude])
        Settings.enabledProviders = [.claude, .cursor]
        XCTAssertEqual(Settings.enabledProviders, [.claude, .cursor])
    }
}
