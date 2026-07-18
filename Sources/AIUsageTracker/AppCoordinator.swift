import AppKit

/// Top-level wiring: owns the menu bar and one independent poller per enabled
/// provider. Each provider has its own poller, on-disk history, and runtime state;
/// a failure in one only updates that provider's error and never disturbs the
/// others. The tray shows each provider's last fetch as a fixed snapshot, so it
/// repaints only when new data/errors arrive — no periodic redraw timer.
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let store = UsageStore()   // per-provider persisted last-fetch time + data

    /// Set to `true` to develop the UI against fake data with no network/Keychain.
    private static let useMockData = false

    /// Everything we keep per running provider.
    private struct Runtime {
        let provider: UsageProvider
        let poller: UsagePoller
        let history: UsageHistory
        var snapshot: ProviderSnapshot?
        var lastUpdated: Date?
        var error: String?
    }
    private var runtimes: [ProviderID: Runtime] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("AI Usage launching (mock=\(Self.useMockData), enabled=\(Settings.enabledProviders.map(\.rawValue).sorted()))")
        LaunchAtLogin.enableByDefaultOnce()

        menuBar.launchAtLoginState = { LaunchAtLogin.isEnabled }
        menuBar.onToggleLaunchAtLogin = { LaunchAtLogin.toggle() }
        menuBar.onRestart = { Relauncher.restartAfterTermination() }
        menuBar.onRefresh = { [weak self] in self?.runtimes.values.forEach { $0.poller.fetchNow() } }
        menuBar.onSetProvider = { [weak self] id, enabled in self?.setProvider(id, enabled: enabled) }

        for id in ProviderID.allCases where Settings.enabledProviders.contains(id) {
            startProvider(id)
        }
        render()
    }

    // MARK: - Provider lifecycle

    private func makeProvider(_ id: ProviderID) -> UsageProvider {
        if Self.useMockData { return MockProvider(id: id) }
        switch id {
        case .claude: return ClaudeUsageFetcher()
        case .codex:  return CodexUsageFetcher()
        case .cursor: return CursorUsageFetcher()
        }
    }

    private func startProvider(_ id: ProviderID) {
        guard runtimes[id] == nil else { return }
        let provider = makeProvider(id)
        let poller = UsagePoller(provider: provider, lastAttemptAt: store.lastFetchAt(id))
        // Show the cached reading immediately (stamped with its real fetch time), so a
        // restart within the cooldown isn't blank while we wait to re-fetch.
        runtimes[id] = Runtime(provider: provider, poller: poller,
                               history: UsageHistory(providerID: id),
                               snapshot: store.snapshot(id), lastUpdated: store.lastFetchAt(id), error: nil)

        poller.onAttempt = { [weak self] at in self?.store.recordAttempt(id, at: at) }
        poller.onData = { [weak self] snapshot in
            guard let self else { return }
            self.store.saveSnapshot(id, snapshot)
            self.runtimes[id]?.snapshot = snapshot
            self.runtimes[id]?.lastUpdated = Date()
            self.runtimes[id]?.error = nil
            self.runtimes[id]?.history.record(snapshot)
            self.render()
        }
        poller.onError = { [weak self] message in
            self?.runtimes[id]?.error = message
            self?.render()
        }
        poller.start()
    }

    private func stopProvider(_ id: ProviderID) {
        runtimes[id]?.poller.stop()
        runtimes[id] = nil
    }

    /// Toggle a provider on/off from the Providers submenu: persist the choice, start
    /// or stop its poller, and repaint.
    private func setProvider(_ id: ProviderID, enabled: Bool) {
        var set = Settings.enabledProviders
        if enabled { set.insert(id) } else { set.remove(id) }
        Settings.enabledProviders = set
        if enabled { startProvider(id) } else { stopProvider(id) }
        Log.log("provider \(id.rawValue) \(enabled ? "enabled" : "disabled")")
        render()
    }

    // MARK: - Render

    /// Assemble the ordered view model (providers in canonical order) and hand it to
    /// the menu bar.
    private func render() {
        let providers = ProviderID.allCases.compactMap { id -> ProviderView? in
            guard let rt = runtimes[id] else { return nil }
            return ProviderView(id: id, displayName: rt.provider.displayName,
                                snapshot: rt.snapshot, lastUpdated: rt.lastUpdated,
                                error: rt.error, history: rt.history.recent())
        }
        menuBar.apply(TrayViewModel(providers: providers, customLimitCents: Settings.customLimitCents))
    }
}
