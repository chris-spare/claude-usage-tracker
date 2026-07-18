import Foundation

/// Resolves the app's on-disk locations (cache, history, logs).
enum AppPaths {
    static let appName = "AISpendTracker"

    /// Application Support directory (cache + per-provider history).
    static let applicationSupport: URL = {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Diagnostic log file.
    static let logFile: URL = {
        let fm = FileManager.default
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("\(appName).log")
    }()
}
