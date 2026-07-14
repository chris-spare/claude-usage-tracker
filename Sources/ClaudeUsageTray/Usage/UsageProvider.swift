import Foundation

/// A source of Claude usage data. The app talks only to this protocol so we can
/// develop the UI against `MockUsageProvider` and later flip to the real fetcher
/// with a one-line change in AppCoordinator.
protocol UsageProvider: Sendable {
    /// Recommended seconds between fetches. Mock ticks fast; the real fetcher must
    /// not exceed once per 5 minutes.
    var suggestedInterval: TimeInterval { get }
    func fetch() async throws -> ClaudeUsageData
}

/// Fixed demo data for UI review — no network, no Keychain. The reset times are
/// anchored to real wall-clock times at construction, so the pies match the
/// intended snapshot now and the *time* arcs keep advancing realistically:
///   • 5-hour:  45% usage, resets today at 1:30 PM   (→ ~73% time, projects ~61%)
///   • 7-day:   54% usage, resets tomorrow at 2:00 PM (→ ~85% time, projects ~64%)
/// Both windows are "under pace" (time ahead of usage → blue surplus).
struct MockUsageProvider: UsageProvider {
    let suggestedInterval: TimeInterval = 60   // constant data; just re-delivers

    private let fiveHour: UsageBucket
    private let sevenDay: UsageBucket

    /// `now` is injectable for tests; defaults to the real clock.
    init(now: Date = Date(), calendar: Calendar = .current) {
        let fiveHourReset = calendar.date(bySettingHour: 13, minute: 30, second: 0, of: now) ?? now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let sevenDayReset = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow) ?? now
        fiveHour = UsageBucket(utilization: 45, resetsAt: fiveHourReset)
        sevenDay = UsageBucket(utilization: 54, resetsAt: sevenDayReset)
    }

    // Illustrative demo figures: $123.45 spent of a $500 monthly limit → ~24.7%.
    private let extra = ExtraUsage(isEnabled: true, usedCents: 12345,
                                   monthlyLimitCents: 50000, utilization: 24.69)

    func fetch() async throws -> ClaudeUsageData {
        ClaudeUsageData(fiveHour: fiveHour, sevenDay: sevenDay, extraUsage: extra)
    }
}
