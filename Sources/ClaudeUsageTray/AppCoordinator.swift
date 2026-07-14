import AppKit

/// Top-level wiring: owns the menu bar, the usage poller, and a redraw timer that
/// keeps the time arcs and countdowns moving between fetches.
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let store = UsageStore()       // persisted last-fetch time + last data
    private let poller: UsagePoller
    private let history = UsageHistory()   // rolling 2h capture for future sparklines
    private var redrawTimer: Timer?

    /// Repaint the tray this often so time arcs advance without a new fetch.
    private static let redrawInterval: TimeInterval = 15

    /// Set to `true` to develop the UI against animated fake data with no network
    /// or Keychain access; `false` fetches live usage from Anthropic.
    private static let useMockData = false

    override init() {
        let provider: UsageProvider
        if Self.useMockData {
            provider = MockUsageProvider()
        } else {
            provider = ClaudeUsageFetcher()
        }
        poller = UsagePoller(provider: provider, lastAttemptAt: store.lastFetchAt)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("Claude Usage launching (mock=\(Self.useMockData))")
        LaunchAtLogin.enableByDefaultOnce()

        menuBar.launchAtLoginState = { LaunchAtLogin.isEnabled }
        menuBar.onToggleLaunchAtLogin = { LaunchAtLogin.toggle() }
        menuBar.onRestart = { Relauncher.restartAfterTermination() }
        menuBar.onRefresh = { [weak self] in self?.poller.fetchNow() }
        menuBar.historyProvider = { [weak self] in self?.history.recent() ?? [] }

        // Show the cached reading immediately (stamped with its real fetch time),
        // so a restart within the cooldown isn't blank while we wait to re-fetch.
        if let cached = store.data, let at = store.lastFetchAt {
            menuBar.update(data: cached, at: at)
        }

        poller.onAttempt = { [weak self] at in self?.store.recordAttempt(at: at) }
        poller.onData = { [weak self] data in
            self?.store.saveData(data)
            self?.menuBar.update(data: data)
            self?.history.record(data)   // capture only; not displayed yet
        }
        poller.onError = { [weak self] message in self?.menuBar.setError(message) }
        poller.start()

        redrawTimer = Timer.scheduledTimer(withTimeInterval: Self.redrawInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuBar.redraw() }
        }
    }
}
