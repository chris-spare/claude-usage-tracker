import Foundation

/// Persists each provider's last fetch attempt time and last successful snapshot to
/// disk, so the app survives its own frequent restarts without re-hitting APIs. On
/// launch we reuse this cache and only fetch a provider once its cooldown since the
/// last *attempt* has elapsed. Keyed by `ProviderID` so providers are independent.
@MainActor
final class UsageStore {
    private struct ProviderCache: Codable {
        var lastFetchAt: Date?
        var snapshot: ProviderSnapshot?
    }
    private struct Cache: Codable {
        var providers: [String: ProviderCache]
    }

    private var cache = Cache(providers: [:])
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppPaths.applicationSupport.appendingPathComponent("usage-cache.json")
        }
        guard let raw = try? Data(contentsOf: self.fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(Cache.self, from: raw) {
            cache = decoded
        } else if let legacy = try? JSONDecoder().decode(LegacyCache.self, from: raw) {
            cache = Self.migrate(legacy)   // pre-multi-provider Claude-only cache
            save()
        }
    }

    func lastFetchAt(_ id: ProviderID) -> Date? { cache.providers[id.rawValue]?.lastFetchAt }
    func snapshot(_ id: ProviderID) -> ProviderSnapshot? { cache.providers[id.rawValue]?.snapshot }

    /// Record that we hit `id`'s API at `date` (success or failure) — the cooldown is
    /// measured from this.
    func recordAttempt(_ id: ProviderID, at date: Date) {
        cache.providers[id.rawValue, default: ProviderCache()].lastFetchAt = date
        save()
    }

    /// Record fresh data from a successful fetch of `id`.
    func saveSnapshot(_ id: ProviderID, _ snapshot: ProviderSnapshot) {
        cache.providers[id.rawValue, default: ProviderCache()].snapshot = snapshot
        save()
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(cache) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }

    // MARK: - Legacy migration (old Claude-only cache shape)

    private struct LegacyBucket: Codable { var utilization: Double; var resetsAt: Date? }
    private struct LegacyExtra: Codable {
        var isEnabled: Bool; var usedCents: Double; var monthlyLimitCents: Double?; var utilization: Double
    }
    private struct LegacyClaudeData: Codable {
        var fiveHour: LegacyBucket?; var sevenDay: LegacyBucket?; var extraUsage: LegacyExtra?
    }
    private struct LegacyCache: Codable { var lastFetchAt: Date?; var data: LegacyClaudeData? }

    private static func migrate(_ legacy: LegacyCache) -> Cache {
        var snapshot: ProviderSnapshot?
        if let d = legacy.data {
            var windows: [UsageWindow] = []
            if let b = d.fiveHour {
                windows.append(UsageWindow(caption: "5-Hour", utilization: b.utilization, resetsAt: b.resetsAt,
                                           timeBasis: .rollingWindow(length: WindowLength.fiveHour)))
            }
            if let b = d.sevenDay {
                windows.append(UsageWindow(caption: "7-Day", utilization: b.utilization, resetsAt: b.resetsAt,
                                           timeBasis: .rollingWindow(length: WindowLength.sevenDay)))
            }
            let spend = d.extraUsage.map {
                SpendInfo(usedCents: $0.usedCents, apiLimitCents: $0.monthlyLimitCents, label: "Claude extra usage")
            }
            snapshot = ProviderSnapshot(windows: windows, spend: spend)
        }
        return Cache(providers: [ProviderID.claude.rawValue:
            ProviderCache(lastFetchAt: legacy.lastFetchAt, snapshot: snapshot)])
    }
}

/// App preferences backed by UserDefaults.
enum Settings {
    private static let customLimitKey = "aiut.customCostTotalCents"
    private static let enabledProvidersKey = "aiut.enabledProviders"

    /// Default combined cost-pie total ($2500). Always set — the cost pie has a
    /// denominator even before the user customizes it.
    static let defaultCustomLimitCents: Double = 250_000

    /// The dollar total (in cents) the combined cost pie fills against.
    static var customLimitCents: Double {
        get { UserDefaults.standard.object(forKey: customLimitKey) as? Double ?? defaultCustomLimitCents }
        set { UserDefaults.standard.set(newValue, forKey: customLimitKey) }
    }

    /// Which providers are shown. Defaults to Claude only (so upgrades from the
    /// single-provider build don't regress); the user turns on Codex/Cursor.
    static var enabledProviders: Set<ProviderID> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: enabledProvidersKey) as? [String] else {
                return [.claude]
            }
            return Set(raw.compactMap(ProviderID.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: enabledProvidersKey)
        }
    }
}
