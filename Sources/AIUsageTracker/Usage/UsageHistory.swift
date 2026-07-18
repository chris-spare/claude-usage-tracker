import Foundation

/// Append-only per-provider log of usage samples (each window's utilization plus
/// month-to-date spend — one row per fetch). One instance and one file per provider
/// (`history-<id>.jsonl`), so providers never contend for the same log. Kept for
/// ~30 days for short-range sparklines now and longer trends later; the sparkline
/// display window is decoupled from this retention.
///
/// Stored as JSONL (one JSON object per line) so each fetch is an O(1) append rather
/// than a full-file rewrite. The file is compacted (pruned + rewritten) on launch
/// and thereafter only once it drifts a day past retention.
@MainActor
final class UsageHistory {
    /// A single point in time. `windows` maps a window caption ("5-Hour", "Weekly",
    /// "Monthly", …) to its utilization %; `spendCents` is month-to-date dollars×100.
    /// Both are optional-friendly (a partial fetch still records what it had).
    struct Sample: Codable, Equatable {
        var date: Date
        var windows: [String: Double]
        var spendCents: Double?

        init(date: Date, windows: [String: Double] = [:], spendCents: Double? = nil) {
            self.date = date
            self.windows = windows
            self.spendCents = spendCents
        }
    }

    /// Old Claude-only row shape, migrated on first load into the generalized form.
    private struct LegacySample: Codable {
        var date: Date
        var fiveHourUtil: Double?
        var sevenDayUtil: Double?
        var spendCents: Double?
    }

    /// Default sparkline display window (independent of on-disk retention).
    static let sparklineWindow: TimeInterval = 2 * 60 * 60

    let retention: TimeInterval
    private let compactionSlack: TimeInterval = 24 * 60 * 60

    private(set) var samples: [Sample] = []
    private let fileURL: URL
    /// Old files to migrate from if the per-provider file doesn't exist yet
    /// (Claude only: the pre-multi-provider `history.jsonl` / legacy `history.json`).
    private let legacySources: [URL]

    /// Production: one file per provider under Application Support.
    convenience init(providerID: ProviderID, retention: TimeInterval = 30 * 24 * 60 * 60) {
        let dir = AppPaths.applicationSupport
        let url = dir.appendingPathComponent("history-\(providerID.rawValue).jsonl")
        let legacy = providerID == .claude
            ? [dir.appendingPathComponent("history.jsonl"), dir.appendingPathComponent("history.json")]
            : []
        self.init(fileURL: url, retention: retention, legacySources: legacy)
    }

    /// Test-friendly: explicit file (and optional legacy sources to exercise migration).
    init(fileURL: URL, retention: TimeInterval = 30 * 24 * 60 * 60, legacySources: [URL] = []) {
        self.fileURL = fileURL
        self.retention = retention
        self.legacySources = legacySources
        load()
    }

    /// Record a fetch's snapshot. Uses `now` (injectable for tests) as the sample time.
    func record(_ snapshot: ProviderSnapshot, now: Date = Date()) {
        var windows: [String: Double] = [:]
        for w in snapshot.windows { windows[w.caption] = w.utilization }
        let sample = Sample(date: now, windows: windows, spendCents: snapshot.spend?.usedCents)
        samples.append(sample)
        append(sample)
        if let oldest = samples.first, now.timeIntervalSince(oldest.date) > retention + compactionSlack {
            prune(now: now)
            rewrite()
        }
    }

    /// Samples within `window` of `now`, oldest first.
    func recent(window: TimeInterval = UsageHistory.sparklineWindow, now: Date = Date()) -> [Sample] {
        samples.filter { now.timeIntervalSince($0.date) <= window }
    }

    // MARK: - Persistence

    private func prune(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.date) > retention }
    }

    private func load() {
        if let raw = try? String(contentsOf: fileURL, encoding: .utf8), !raw.isEmpty {
            samples = Self.decodeJSONL(raw)
        } else if let migrated = migrateLegacy() {
            samples = migrated
            rewrite()   // write the migrated data into the per-provider file
        }
        prune(now: Date())
        rewrite()   // compact on launch
    }

    /// Migrate the first present legacy source (new-format JSONL, old-format JSONL, or
    /// the oldest JSON array), converting old Claude rows to the generalized shape.
    private func migrateLegacy() -> [Sample]? {
        for url in legacySources {
            guard let raw = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: raw, as: UTF8.self)
            let samples: [Sample]
            if let arr = try? JSONDecoder().decode([Sample].self, from: raw) {
                samples = arr                               // legacy JSON array, new shape
            } else if let legacyArr = try? JSONDecoder().decode([LegacySample].self, from: raw) {
                samples = legacyArr.map(Self.convert)       // legacy JSON array, old shape
            } else {
                samples = Self.decodeJSONL(text)            // JSONL (new or old shape per line)
            }
            try? FileManager.default.removeItem(at: url)
            if !samples.isEmpty { return samples }
        }
        return nil
    }

    /// Decode JSONL, tolerating both the new `Sample` shape and the old Claude shape
    /// on a per-line basis.
    private static func decodeJSONL(_ raw: String) -> [Sample] {
        let decoder = JSONDecoder()
        return raw.split(separator: "\n").compactMap { line in
            let data = Data(line.utf8)
            if let s = try? decoder.decode(Sample.self, from: data), !s.windows.isEmpty || s.spendCents != nil {
                return s
            }
            if let legacy = try? decoder.decode(LegacySample.self, from: data) {
                return convert(legacy)
            }
            return try? decoder.decode(Sample.self, from: data)   // empty-but-valid new row
        }
    }

    private static func convert(_ legacy: LegacySample) -> Sample {
        var windows: [String: Double] = [:]
        if let v = legacy.fiveHourUtil { windows["5-Hour"] = v }
        if let v = legacy.sevenDayUtil { windows["7-Day"] = v }
        return Sample(date: legacy.date, windows: windows, spendCents: legacy.spendCents)
    }

    private func append(_ sample: Sample) {
        guard var line = try? JSONEncoder().encode(sample) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: fileURL, options: .atomic)
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
