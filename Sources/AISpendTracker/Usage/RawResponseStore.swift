import Foundation

/// Persists each provider's most recent raw response body (whatever the single
/// request returned — a parsed JSON payload, an HTTP-error body, or an unparseable
/// response) to its own JSON file, so the "copy last response" affordance works for
/// debugging and error reports even straight after a restart. Keyed by `ProviderID`;
/// each attempt overwrites the previous entry, so this is "what the server last sent
/// us," not a history.
@MainActor
final class RawResponseStore {
    private struct Entry: Codable {
        var raw: String
        var at: Date
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.applicationSupport.appendingPathComponent("raw-responses.json")
        guard let data = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    /// The last raw response recorded for `id`, or nil if none yet.
    func raw(_ id: ProviderID) -> String? { entries[id.rawValue]?.raw }

    /// Overwrite `id`'s last raw response.
    func record(_ id: ProviderID, raw: String, at: Date) {
        entries[id.rawValue] = Entry(raw: raw, at: at)
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
