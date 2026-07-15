import Foundation

/// Drives a `UsageProvider` while respecting a minimum interval (cooldown) between
/// API hits — including across app restarts. Given the timestamp of the last
/// attempt (from the persisted store), on `start()` it fetches immediately only if
/// the cooldown has already elapsed; otherwise it waits out the remainder. After
/// every attempt (success or failure) it schedules the next one a full cooldown
/// later, so the API is never hit more than once per `cooldown`.
@MainActor
final class UsagePoller {
    private let provider: UsageProvider
    private let cooldown: TimeInterval
    private var lastAttemptAt: Date?
    private var timer: Timer?
    private var stopped = false

    /// Called just before each network attempt, with its timestamp (persist this
    /// so the cooldown survives restarts).
    var onAttempt: ((Date) -> Void)?
    /// Called with each successful fetch.
    var onData: ((ClaudeUsageData) -> Void)?
    /// Called with a short, user-facing message when a fetch fails.
    var onError: ((String) -> Void)?

    init(provider: UsageProvider, lastAttemptAt: Date?) {
        self.provider = provider
        self.cooldown = provider.suggestedInterval
        self.lastAttemptAt = lastAttemptAt
    }

    /// Begin polling. Honors the cooldown relative to the last persisted attempt.
    func start() {
        scheduleNext()
    }

    /// Force an immediate fetch (the menu's "Refresh Now"), bypassing the cooldown.
    func fetchNow() {
        fetch()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    /// Schedule the next fetch: now if the cooldown has elapsed since the last
    /// attempt, else after the remainder.
    private func scheduleNext() {
        guard !stopped else { return }
        let elapsed = lastAttemptAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0, cooldown - elapsed)
        timer?.invalidate()
        if delay <= 0 {
            fetch()
        } else {
            Log.log("usage: within cooldown — next fetch in \(Int(delay))s (reusing cache)")
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.fetch() }
            }
        }
    }

    private func fetch() {
        guard !stopped else { return }
        let now = Date()
        lastAttemptAt = now
        onAttempt?(now)
        let provider = self.provider
        Task { [weak self] in
            do {
                let data = try await provider.fetch()
                let f = data.fiveHour.map { "\(Int($0.utilization))%" } ?? "—"
                let s = data.sevenDay.map { "\(Int($0.utilization))%" } ?? "—"
                Log.log("usage: fetched (5h=\(f), 7d=\(s))")
                self?.onData?(data)
                self?.scheduleAfterAttempt()
            } catch {
                let (message, permanent) = UsagePoller.describe(error)
                Log.log("usage: fetch failed (\(permanent ? "permanent" : "will retry")): \(error)")
                self?.onError?(message)
                if permanent { self?.stop() } else { self?.scheduleAfterAttempt() }
            }
        }
    }

    /// Turn a fetch error into a specific, user-facing message and whether it's
    /// permanent (stop polling) or transient (retry next cooldown).
    private static func describe(_ error: Error) -> (message: String, permanent: Bool) {
        switch error {
        case is ClaudeUsageFetcher.NoOAuthCredentialsError:
            return ("No Claude subscription credentials in Keychain (API-key account?)", true)
        case let e as ClaudeUsageFetcher.KeychainError:
            return ("Keychain read failed: \(e.detail)", false)
        case let e as ClaudeUsageFetcher.UsageAPIError:
            return (e.userMessage, false)
        case let e as URLError:
            return ("Network error: \(e.localizedDescription)", false)
        case is DecodingError:
            return ("Couldn't parse the usage response", false)
        default:
            return ("Fetch failed: \(error.localizedDescription)", false)
        }
    }

    /// After any completed attempt, wait a full cooldown before the next.
    private func scheduleAfterAttempt() {
        guard !stopped else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: cooldown, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch() }
        }
    }
}
