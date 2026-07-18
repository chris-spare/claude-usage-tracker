import Foundation

/// Live usage for OpenAI Codex CLI (ChatGPT-authenticated). Mirrors what the
/// `codex` CLI's `/status` does:
///   • read the bearer token + account id from `~/.codex/auth.json` (the CLI
///     refreshes this file itself; we only read it — never write, to avoid racing
///     the running CLI);
///   • GET https://chatgpt.com/backend-api/wham/usage with the bearer token and the
///     ChatGPT-Account-Id header.
///
/// The payload carries `rate_limit.primary_window` / `secondary_window` (on paid
/// plans a 5-hour + weekly pair; on the free plan a single ~30-day window) plus
/// `spend_control.individual_limit` (pay-as-you-go overage) and `credits`.
final class CodexUsageFetcher: UsageProvider, @unchecked Sendable {
    let id: ProviderID = .codex
    let displayName = "Codex"
    let suggestedInterval: TimeInterval = 5 * 60

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let userAgent = "codex-usage-tray"
    private static let timeout: TimeInterval = 5

    /// `~/.codex/auth.json` is missing or has no access token — Codex isn't logged in.
    struct NoAuthError: Error {}
    /// The usage endpoint returned a non-2xx status.
    struct UsageAPIError: Error { let status: Int; let body: String }

    private let authPath: URL

    init(authPath: URL? = nil) {
        self.authPath = authPath
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    func fetch() async throws -> ProviderSnapshot {
        let (token, accountId) = try readAuth()

        var req = URLRequest(url: Self.usageURL, timeoutInterval: Self.timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageAPIError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decode(data)
    }

    func classify(_ error: Error) -> (message: String, permanent: Bool) {
        switch error {
        case is NoAuthError:
            return ("Not logged in to Codex (~/.codex/auth.json missing)", true)
        case let e as UsageAPIError where e.status == 401:
            return ("Codex token expired — open Codex to refresh it", false)
        case let e as UsageAPIError:
            return ("Codex usage API returned \(e.status)", false)
        case let e as URLError:
            return ("Network error: \(e.localizedDescription)", false)
        case is DecodingError:
            return ("Couldn't parse the Codex usage response", false)
        default:
            return ("Fetch failed: \(error.localizedDescription)", false)
        }
    }

    // MARK: - Auth

    private func readAuth() throws -> (token: String, accountId: String) {
        guard let raw = try? Data(contentsOf: authPath),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw NoAuthError()
        }
        let accountId = (tokens["account_id"] as? String) ?? ""
        return (token, accountId)
    }

    // MARK: - Decode

    /// Map the `wham/usage` payload into a `ProviderSnapshot`. Both windows are
    /// optional (free plans have only `primary_window`); missing fields read as an
    /// idle window rather than failing the fetch.
    static func decode(_ data: Data) throws -> ProviderSnapshot {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Double?
            let reset_at: Double?
        }
        struct RateLimit: Decodable { let primary_window: Window?; let secondary_window: Window? }
        struct SpendLimit: Decodable { let limit: String?; let used: String?; let remaining: String? }
        struct SpendControl: Decodable { let individual_limit: SpendLimit? }
        struct Payload: Decodable {
            let plan_type: String?
            let rate_limit: RateLimit?
            let spend_control: SpendControl?
        }

        func window(_ w: Window?) -> UsageWindow? {
            guard let w, let seconds = w.limit_window_seconds, seconds > 0 else { return nil }
            let reset = w.reset_at.map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(caption: WindowCaption.forLength(seconds),
                               utilization: w.used_percent ?? 0, resetsAt: reset,
                               timeBasis: .rollingWindow(length: seconds))
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let windows = [payload.rate_limit?.primary_window, payload.rate_limit?.secondary_window]
            .compactMap(window)

        // Overage: `individual_limit` carries dollar strings; contribute only when a
        // limit is actually configured (nil on free plans → no spend).
        var spend: SpendInfo?
        if let limit = payload.spend_control?.individual_limit,
           let usedDollars = limit.used.flatMap(Double.init) {
            spend = SpendInfo(usedCents: usedDollars * 100,
                              apiLimitCents: limit.limit.flatMap(Double.init).map { $0 * 100 },
                              label: "Codex overage")
        }
        return ProviderSnapshot(windows: windows, spend: spend)
    }
}
