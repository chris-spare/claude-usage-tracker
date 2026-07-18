import Foundation

/// Resolves the app's on-disk locations, migrating from the pre-rename
/// "ClaudeUsageTray" names on first use so existing cache/history/logs carry over.
enum AppPaths {
    static let appName = "AIUsageTracker"
    private static let legacyName = "ClaudeUsageTray"

    /// Application Support directory (cache + per-provider history). The whole legacy
    /// folder is moved across on first launch, so every file inside migrates at once.
    static let applicationSupport: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Diagnostic log file, migrating the legacy file on first use.
    static let logFile: URL = {
        let fm = FileManager.default
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("\(appName).log")
        let legacy = logs.appendingPathComponent("\(legacyName).log")
        if !fm.fileExists(atPath: file.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: file)
        }
        return file
    }()
}
