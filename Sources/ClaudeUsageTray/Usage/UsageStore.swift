import Foundation

/// Persists the last fetch attempt time and the last successful data to disk, so
/// the app can survive its own frequent restarts without re-hitting the API. On
/// launch we reuse this cache and only fetch once the 5-minute cooldown since the
/// last *attempt* has elapsed.
@MainActor
final class UsageStore {
    private struct Cache: Codable {
        var lastFetchAt: Date?
        var data: ClaudeUsageData?
    }

    private var cache = Cache()
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsageTray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("usage-cache.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Cache.self, from: raw) {
            cache = decoded
        }
    }

    var lastFetchAt: Date? { cache.lastFetchAt }
    var data: ClaudeUsageData? { cache.data }

    /// Record that we hit the API at `date` (success or failure) — this is what the
    /// cooldown is measured from.
    func recordAttempt(at date: Date) {
        cache.lastFetchAt = date
        save()
    }

    /// Record fresh data from a successful fetch.
    func saveData(_ data: ClaudeUsageData) {
        cache.data = data
        save()
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(cache) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }
}

/// App preferences backed by UserDefaults.
enum Settings {
    private static let customLimitKey = "cut.customMonthlyLimitCents"

    /// A user-set monthly spend limit (in cents) that overrides the API-supplied
    /// limit for the spend circle. nil when not configured.
    static var customLimitCents: Double? {
        get { UserDefaults.standard.object(forKey: customLimitKey) as? Double }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: customLimitKey) }
            else { UserDefaults.standard.removeObject(forKey: customLimitKey) }
        }
    }
}
