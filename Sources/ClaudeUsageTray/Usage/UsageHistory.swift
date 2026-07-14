import Foundation

/// Append-only log of usage samples (5-hour util, 7-day util, and month-to-date
/// spend — one row captures all three per fetch). Kept for ~30 days so we can show
/// short-range sparklines now and longer-range trends later; the sparkline display
/// window is decoupled from this retention.
///
/// Stored as JSONL (one JSON object per line) so each fetch is an O(1) append
/// rather than a full-file rewrite. The file is compacted (pruned + rewritten) on
/// launch and, thereafter, only once it drifts a day past the retention horizon —
/// so at 30-day retention it holds ≲9k tiny rows (~1 MB).
@MainActor
final class UsageHistory {
    /// A single point in time. Fields are optional so a partial fetch still records
    /// what it had. `spendCents` is month-to-date dollars×100.
    struct Sample: Codable, Equatable {
        var date: Date
        var fiveHourUtil: Double?
        var sevenDayUtil: Double?
        var spendCents: Double?
    }

    /// Default sparkline display window (independent of on-disk retention).
    static let sparklineWindow: TimeInterval = 2 * 60 * 60

    /// How long samples are kept on disk.
    let retention: TimeInterval
    /// Rewrite the file to prune only once it's this far past retention, so we don't
    /// rewrite on every append once at steady state (batches compaction to ~daily).
    private let compactionSlack: TimeInterval = 24 * 60 * 60

    private(set) var samples: [Sample] = []
    private let fileURL: URL
    private let legacyURL: URL?   // old JSON-array file to migrate from, if present

    /// `fileURL` is overridable for tests; production uses Application Support.
    init(retention: TimeInterval = 30 * 24 * 60 * 60, fileURL: URL? = nil) {
        self.retention = retention
        if let fileURL {
            self.fileURL = fileURL
            legacyURL = nil
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClaudeUsageTray", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("history.jsonl")
            legacyURL = dir.appendingPathComponent("history.json")
        }
        load()
    }

    /// Record a fetch. Uses `now` (injectable for tests) as the sample time.
    func record(_ data: ClaudeUsageData, now: Date = Date()) {
        let sample = Sample(
            date: now,
            fiveHourUtil: data.fiveHour?.utilization,
            sevenDayUtil: data.sevenDay?.utilization,
            spendCents: data.extraUsage?.usedCents)
        samples.append(sample)
        append(sample)
        // Only compact once we've drifted well past retention, to avoid rewriting
        // the whole file on every append at steady state.
        if let oldest = samples.first, now.timeIntervalSince(oldest.date) > retention + compactionSlack {
            prune(now: now)
            rewrite()
        }
    }

    /// Samples within `window` of `now`, oldest first. Defaults to the sparkline
    /// window; pass a larger window (up to `retention`) for longer-range views.
    func recent(window: TimeInterval = UsageHistory.sparklineWindow, now: Date = Date()) -> [Sample] {
        samples.filter { now.timeIntervalSince($0.date) <= window }
    }

    // MARK: - Persistence

    private func prune(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.date) > retention }
    }

    private func load() {
        if let raw = try? String(contentsOf: fileURL, encoding: .utf8) {
            let decoder = JSONDecoder()
            samples = raw.split(separator: "\n").compactMap {
                try? decoder.decode(Sample.self, from: Data($0.utf8))
            }
        } else if let legacyURL, let raw = try? Data(contentsOf: legacyURL),
                  let arr = try? JSONDecoder().decode([Sample].self, from: raw) {
            // Migrate the old JSON-array file, then retire it.
            samples = arr
            try? FileManager.default.removeItem(at: legacyURL)
        }
        prune(now: Date())
        rewrite()   // compact on launch
    }

    private func append(_ sample: Sample) {
        guard var line = try? JSONEncoder().encode(sample) else { return }
        line.append(0x0A)   // newline
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: fileURL, options: .atomic)   // file didn't exist yet
        }
    }

    private func rewrite() {
        let encoder = JSONEncoder()
        let body = samples.compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        let out = body.isEmpty ? "" : body + "\n"
        try? out.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
