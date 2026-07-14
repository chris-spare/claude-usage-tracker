import Foundation

/// One rate-limit window's usage, mirroring the Anthropic OAuth usage payload.
/// `utilization` is a percentage in 0…100 (it can momentarily read slightly above
/// 100 near the cap). `resetsAt` is when this window rolls over to empty.
struct UsageBucket: Equatable, Codable {
    var utilization: Double
    var resetsAt: Date
}

/// Month-to-date spend ("extra usage" / pay-as-you-go credits), mirroring the
/// API's `extra_usage`. Amounts are in cents. `monthlyLimitCents` is nil when no
/// cap is configured. `utilization` is a 0…100 percentage of the limit.
struct ExtraUsage: Equatable, Codable {
    var isEnabled: Bool
    var usedCents: Double
    var monthlyLimitCents: Double?
    var utilization: Double
}

/// The two rate-limit windows plus month-to-date spend. Any field may be nil if
/// the API omits it.
struct ClaudeUsageData: Equatable, Codable {
    var fiveHour: UsageBucket?
    var sevenDay: UsageBucket?
    var extraUsage: ExtraUsage?
}

/// Fixed window lengths for the two buckets.
enum UsageWindow {
    static let fiveHour: TimeInterval = 5 * 60 * 60
    static let sevenDay: TimeInterval = 7 * 24 * 60 * 60
}
