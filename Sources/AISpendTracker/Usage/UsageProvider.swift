import Foundation

/// A source of usage data for one AI coding tool. The app talks only to this
/// protocol so providers are interchangeable and each owns its own auth, endpoint,
/// polling cadence, and error taxonomy. Kept AppKit-free — per-provider colors live
/// in the render layer, keyed by `id`.
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    /// Recommended seconds between fetches; the poller never fetches faster.
    var suggestedInterval: TimeInterval { get }
    func fetch() async throws -> ProviderSnapshot
    /// Turn a fetch error into a short, user-facing message and whether it's
    /// permanent (stop polling this provider) or transient (retry next cooldown).
    func classify(_ error: Error) -> (message: String, permanent: Bool)
}

/// Fixed demo data for UI review — no network, no Keychain. Reset times are anchored
/// to real wall-clock times so the pies match the intended snapshot and the *time*
/// arcs keep advancing. Each mock provider mimics the real shape of its counterpart.
struct MockProvider: UsageProvider {
    let id: ProviderID
    let displayName: String
    let suggestedInterval: TimeInterval = 60
    private let snapshot: ProviderSnapshot

    init(id: ProviderID, now: Date = Date(), calendar: Calendar = .current) {
        self.id = id
        switch id {
        case .claude:
            displayName = "Claude"
            let fiveReset = calendar.date(bySettingHour: 13, minute: 30, second: 0, of: now) ?? now
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            let sevenReset = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow) ?? now
            snapshot = ProviderSnapshot(
                windows: [
                    UsageWindow(caption: "5-Hour", utilization: 45, resetsAt: fiveReset,
                                timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
                    UsageWindow(caption: "7-Day", utilization: 54, resetsAt: sevenReset,
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
                ],
                spend: SpendInfo(usedCents: 12345, apiLimitCents: 50000, label: "Claude extra usage"))
        case .codex:
            displayName = "Codex"
            let reset = calendar.date(byAdding: .hour, value: 3, to: now) ?? now
            snapshot = ProviderSnapshot(
                windows: [
                    UsageWindow(caption: "5-Hour", utilization: 30, resetsAt: reset,
                                timeBasis: .rollingWindow(length: WindowLength.fiveHour)),
                    UsageWindow(caption: "Weekly", utilization: 62,
                                resetsAt: calendar.date(byAdding: .day, value: 4, to: now),
                                timeBasis: .rollingWindow(length: WindowLength.sevenDay)),
                ],
                spend: SpendInfo(usedCents: 800, apiLimitCents: nil, label: "Codex overage"))
        case .cursor:
            displayName = "Cursor"
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
            snapshot = ProviderSnapshot(
                windows: [
                    UsageWindow(caption: "Monthly", utilization: 18, resetsAt: end,
                                timeBasis: .interval(start: start, end: end)),
                ],
                spend: SpendInfo(usedCents: 4200, apiLimitCents: 150000, label: "Cursor on-demand"))
        }
    }

    func fetch() async throws -> ProviderSnapshot { snapshot }
    func classify(_ error: Error) -> (message: String, permanent: Bool) {
        (error.localizedDescription, false)
    }
}
