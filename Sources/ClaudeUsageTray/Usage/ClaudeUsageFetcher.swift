import Foundation

/// The live usage provider. Mirrors SpaceTerm's `claude-usage.ts`:
///   • read the OAuth token from the login Keychain item "Claude Code-credentials"
///     (account = $USER) by shelling out to `security` (avoids Keychain-entitlement
///     fuss; the item's ACL trusts /usr/bin/security);
///   • GET https://api.anthropic.com/api/oauth/usage with the OAuth bearer token.
///
/// Cadence: the caller must not fetch more than once per 5 minutes.
final class ClaudeUsageFetcher: UsageProvider, @unchecked Sendable {
    /// Never faster than once per 5 minutes (Anthropic usage endpoint).
    let suggestedInterval: TimeInterval = 5 * 60

    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let userAgent = "claude-code/2.1.47"
    private static let timeout: TimeInterval = 5

    /// No OAuth credentials exist (item not found) — an API-key account rather than
    /// a Claude.ai subscription. Polling should stop permanently.
    struct NoOAuthCredentialsError: Error {}
    /// `security` failed for a transient reason (keychain locked, prompt dismissed,
    /// etc.) — worth retrying. `detail` carries the tool's stderr.
    struct KeychainError: Error { let detail: String }
    /// The usage endpoint returned a non-2xx status.
    struct UsageAPIError: Error {
        let status: Int
        let body: String

        /// A concise, user-facing line: prefers the API's `error.message`, else a
        /// trimmed one-line snippet of the body.
        var userMessage: String {
            let snippet = Self.snippet(from: body)
            return snippet.isEmpty ? "Usage API returned \(status)" : "Usage API \(status): \(snippet)"
        }

        private static func snippet(from body: String) -> String {
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String { return message }
            let oneLine = body.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(oneLine.prefix(120))
        }
    }

    func fetch() async throws -> ClaudeUsageData {
        let token = try Self.readAccessToken()

        var req = URLRequest(url: Self.usageURL, timeoutInterval: Self.timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageAPIError(status: http.statusCode,
                                body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decode(data)
    }

    // MARK: - Keychain

    /// Read the `claudeAiOauth.accessToken` from the Keychain via `security`.
    private static func readAccessToken() throws -> String {
        let raw = try runSecurity()
        guard let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw NoOAuthCredentialsError()
        }
        return token
    }

    private static func runSecurity() throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", keychainService,
                          "-a", NSUserName(), "-w"]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            // 44 = errSecItemNotFound → genuinely no credentials (stop permanently).
            // Any other failure (locked keychain, denied prompt, …) is transient.
            if task.terminationStatus == 44 { throw NoOAuthCredentialsError() }
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw KeychainError(detail: stderr.isEmpty ? "security exited \(task.terminationStatus)" : stderr)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw NoOAuthCredentialsError() }
        return trimmed
    }

    // MARK: - Decode

    /// The payload has more buckets (seven_day_opus, extra_usage, …); we take only
    /// the two we chart. `resets_at` is an ISO-8601 timestamp — but the API returns
    /// it (and utilization) as `null` for an inactive/empty window, so both are
    /// optional and such a bucket simply reads as "no data" rather than failing the
    /// whole fetch.
    static func decode(_ data: Data) throws -> ClaudeUsageData {
        struct Bucket: Decodable { let utilization: Double?; let resets_at: String? }
        struct Extra: Decodable {
            let is_enabled: Bool?
            let monthly_limit: Double?
            let used_credits: Double?
            let utilization: Double?
        }
        struct Payload: Decodable {
            let five_hour: Bucket?
            let seven_day: Bucket?
            let extra_usage: Extra?
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        // A window always renders: null/missing fields mean an idle window, shown
        // as 0% usage / 0% time (it starts when first used), never "no data".
        func parseWindow(_ b: Bucket?) -> UsageBucket {
            var date: Date?
            if let s = b?.resets_at { date = iso.date(from: s) ?? isoNoFrac.date(from: s) }
            return UsageBucket(utilization: b?.utilization ?? 0, resetsAt: date)
        }
        func parseExtra(_ e: Extra?) -> ExtraUsage? {
            guard let e else { return nil }
            let used = e.used_credits ?? 0
            let util = e.utilization ?? {
                if let limit = e.monthly_limit, limit > 0 { return used / limit * 100 }
                return 0
            }()
            return ExtraUsage(isEnabled: e.is_enabled ?? false, usedCents: used,
                              monthlyLimitCents: e.monthly_limit, utilization: util)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return ClaudeUsageData(fiveHour: parseWindow(payload.five_hour),
                               sevenDay: parseWindow(payload.seven_day),
                               extraUsage: parseExtra(payload.extra_usage))
    }
}
