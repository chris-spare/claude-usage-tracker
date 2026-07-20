import Foundation

/// The AI coding tools we can track. `rawValue` is used as the persistence key
/// (cache/history filenames, enabled-set storage) so it must stay stable.
/// `CaseIterable` order is the canonical left-to-right pie/section order.
enum ProviderID: String, CaseIterable, Codable {
    case claude, codex, cursor
}

/// How a window's elapsed-time wedge (the gray/dark pie layer) is computed.
/// Different providers express their windows differently:
///   • `rollingWindow` — a fixed-length window that rolls over at `resetsAt`
///     (Claude 5h/7d, Codex primary/secondary). Elapsed = length − (resetsAt − now).
///   • `interval` — an explicit start…end span (Cursor's monthly billing cycle).
///   • `none` — no time information; the wedge reads as empty.
enum TimeBasis: Codable, Equatable {
    case rollingWindow(length: TimeInterval)
    case interval(start: Date, end: Date)
    case none
}

/// One rate-limit window — renders as one pie. `utilization` is a 0…100 percentage
/// (it can momentarily read slightly above 100 near a cap; text shows the raw value,
/// the ring clamps). `resetsAt` is when the window rolls over (also drives the
/// countdown text); nil for an idle window that hasn't started.
struct UsageWindow: Codable, Equatable {
    var caption: String
    var utilization: Double
    var resetsAt: Date?
    var timeBasis: TimeBasis
    /// Whether an end-of-window projection is meaningful (rolling/interval windows
    /// where "on pace" makes sense). Providers without a stable pace set this false.
    var supportsProjection: Bool
    /// A per-model scoped window (e.g. Claude's "Fable 7-Day") rather than one of the
    /// account-wide primary windows. Rendered in a distinct color so it doesn't read
    /// as another primary usage window.
    var isScoped: Bool

    init(caption: String, utilization: Double, resetsAt: Date?,
         timeBasis: TimeBasis, supportsProjection: Bool = true, isScoped: Bool = false) {
        self.caption = caption
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.timeBasis = timeBasis
        self.supportsProjection = supportsProjection
        self.isScoped = isScoped
    }
}

/// A provider's month-to-date overage / pay-as-you-go spend, in cents. All enabled
/// providers' `usedCents` are summed into the single combined spend pie.
/// `apiLimitCents` is the provider-reported cap (informational only — the spend pie
/// fills against the user's own spend total). `label` names the source in the menu.
struct SpendInfo: Codable, Equatable {
    var usedCents: Double
    var apiLimitCents: Double?
    var label: String
}

/// What every provider returns from a successful fetch: an ordered list of windows
/// (0…N pies) plus an optional spend contribution.
struct ProviderSnapshot: Codable, Equatable {
    var windows: [UsageWindow]
    var spend: SpendInfo?

    init(windows: [UsageWindow] = [], spend: SpendInfo? = nil) {
        self.windows = windows
        self.spend = spend
    }
}

/// Fixed window lengths shared by the fetchers.
enum WindowLength {
    static let fiveHour: TimeInterval = 5 * 60 * 60
    static let sevenDay: TimeInterval = 7 * 24 * 60 * 60
}

/// Derives a short, role-based caption from a rolling window's length, so a provider
/// that changes its windows (e.g. Codex going from a single monthly free-plan window
/// to a paid 5-hour + weekly pair) is labeled correctly with no code change.
enum WindowCaption {
    static func forLength(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<(6 * 3600):      return "5-Hour"
        case ..<(2 * 86400):     return "Daily"
        case ..<(8 * 86400):     return "Weekly"
        default:                 return "Monthly"
        }
    }
}
