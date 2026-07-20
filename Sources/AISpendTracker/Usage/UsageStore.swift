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
        guard let raw = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode(Cache.self, from: raw) else { return }
        cache = decoded
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
}

/// How the combined spend is shown in the menu bar: as the pie ring (default), as a
/// pace-colored dollar figure, or not at all. Only governs the tray glyph — the
/// dropdown always keeps the rich spend ring.
enum SpendDisplayMode: String, CaseIterable {
    case circle, text, off
}

/// App preferences backed by UserDefaults.
enum Settings {
    private static let customLimitKey = "aiut.customCostTotalCents"
    private static let enabledProvidersKey = "aiut.enabledProviders"
    private static let spendDisplayKey = "aiut.spendDisplayMode"

    /// Default combined spend-pie total ($2500). Always set — the spend pie has a
    /// denominator even before the user customizes it.
    static let defaultCustomLimitCents: Double = 250_000

    /// The dollar total (in cents) the combined spend pie fills against. May be 0,
    /// which turns the spend ring into a plain "any spend at all" indicator (empty at
    /// $0, full above) — see `UsageMath.spendFraction` / `spendStatus`.
    static var customLimitCents: Double {
        get { UserDefaults.standard.object(forKey: customLimitKey) as? Double ?? defaultCustomLimitCents }
        set { UserDefaults.standard.set(newValue, forKey: customLimitKey) }
    }

    /// How the combined spend renders in the menu bar (default: the pie ring).
    static var spendDisplayMode: SpendDisplayMode {
        get { SpendDisplayMode(rawValue: UserDefaults.standard.string(forKey: spendDisplayKey) ?? "") ?? .circle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: spendDisplayKey) }
    }

    /// Which providers are shown. On first run — nothing persisted yet — all
    /// providers are enabled. After that the user's explicit choice is honored,
    /// including turning them all off (which persists as an empty selection, kept
    /// distinct from the never-set state by the key's absence).
    static var enabledProviders: Set<ProviderID> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: enabledProvidersKey) as? [String] else {
                return Set(ProviderID.allCases)
            }
            return Set(raw.compactMap(ProviderID.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: enabledProvidersKey)
        }
    }
}
