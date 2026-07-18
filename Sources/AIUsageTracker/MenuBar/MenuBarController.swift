import AppKit

/// Owns the menu-bar status item (the donut charts) and the details dropdown. The
/// menu is rebuilt from the current `TrayViewModel`: an app title, the big rings
/// header, one section per enabled provider (its windows, or an error + Copy Error
/// when its last fetch failed), a combined cost section, then the footer (Providers
/// submenu, updated line, Open at Login / Refresh / Restart / Quit).
///
/// The tray image and header render the **snapshot as of each provider's last
/// fetch** (see `PieChart.circles`), so the time arc isn't misrepresented by drift;
/// only the reset countdowns tick against the live clock (refreshed on menu open).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let ringsHeader = RingsHeaderView(frame: NSRect(x: 0, y: 0, width: 220, height: 82))

    /// Latest state to render. Replaced wholesale by `apply(_:)`.
    private var vm = TrayViewModel(providers: [], customLimitCents: Settings.defaultCustomLimitCents)

    var onRefresh: (() -> Void)?
    var onRestart: (() -> Void)?
    var launchAtLoginState: (() -> Bool)?
    var onToggleLaunchAtLogin: (() -> Bool)?
    /// Enable/disable a provider (persists + starts/stops its poller in the coordinator).
    var onSetProvider: ((ProviderID, Bool) -> Void)?

    /// Human names for every provider (the submenu lists all, enabled or not).
    private static let displayNames: [ProviderID: String] = [
        .claude: "Claude", .codex: "Codex", .cursor: "Cursor",
    ]

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(now: Date())
        redraw(now: Date())
    }

    // MARK: - Data in

    /// Hand in fresh state and repaint everything.
    func apply(_ vm: TrayViewModel) {
        self.vm = vm
        rebuildMenu(now: Date())
        redraw(now: Date())
    }

    /// Repaint the tray icon from the current view model.
    private func redraw(now: Date) {
        guard let button = statusItem.button else { return }
        button.image = PieChart.trayImage(from: vm, now: now)
        let errored = vm.providers.filter { $0.error != nil }.map(\.displayName)
        button.image?.accessibilityDescription = errored.isEmpty
            ? "AI usage across \(vm.providers.count) provider(s)"
            : "AI usage — fetch failed for: \(errored.joined(separator: ", "))"
    }

    // Refresh countdowns/ago against the live clock each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(now: Date())
    }

    // MARK: - Menu construction

    private func rebuildMenu(now: Date) {
        menu.removeAllItems()

        let title = Self.disabledItem("AI Usage Tracker")
        title.attributedTitle = NSAttributedString(string: "AI Usage Tracker", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)])
        menu.addItem(title)
        menu.addItem(.separator())

        // Big rings mirror the tray image — shown only when there's something to draw
        // (no enabled providers, or none fetched yet → omit the header entirely).
        let circles = PieChart.circles(from: vm, now: now)
        if !circles.isEmpty {
            ringsHeader.circles = circles
            ringsHeader.setFrameSize(NSSize(width: ringsHeader.preferredWidth, height: ringsHeader.preferredHeight))
            let headerItem = Self.disabledItem("")
            headerItem.view = ringsHeader
            menu.addItem(headerItem)
            menu.addItem(.separator())
        }

        for p in vm.providers {
            addProviderSection(p, now: now)
            menu.addItem(.separator())
        }

        if vm.hasAnySpend { addCostSection(); menu.addItem(.separator()) }

        addFooter(now: now)
    }

    /// One provider's section: a colored title, then either its window rows or an
    /// error line + a Copy Error action.
    private func addProviderSection(_ p: ProviderView, now: Date) {
        let titleItem = Self.disabledItem(p.displayName)
        titleItem.attributedTitle = NSAttributedString(string: p.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
            .foregroundColor: PieChart.palette(for: p.id).usage])
        menu.addItem(titleItem)

        if let error = p.error {
            let msg = Self.disabledItem(error)
            msg.attributedTitle = NSAttributedString(string: error, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(msg)
            let copy = NSMenuItem(title: "Copy Error", action: #selector(copyError(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = error
            menu.addItem(copy)
            return
        }

        guard let snap = p.snapshot else {
            menu.addItem(Self.disabledItem("No data yet"))   // enabled, not fetched yet
            return
        }
        guard !snap.windows.isEmpty else {
            // Fetched fine, but this plan exposes no rate-limit window (e.g. a
            // usage-based account) — so there's no circle to draw for it.
            menu.addItem(Self.disabledItem("No usage window on this plan"))
            return
        }

        let at = p.lastUpdated ?? now   // usage/projection are as of the last fetch
        for window in snap.windows {
            let caption = Self.disabledItem(window.caption)
            caption.attributedTitle = NSAttributedString(string: window.caption, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)])
            menu.addItem(caption)
            menu.addItem(Self.disabledItem(usageLine(window, at: at)))
            menu.addItem(Self.disabledItem(resetLine(window, now: now)))
            addRecentPeak(points: p.series(forWindow: window.caption), unit: .percent)
        }
    }

    /// The combined cost section: total spend, per-provider breakdown, cost total,
    /// and "Set Custom Cost Total…".
    private func addCostSection() {
        let title = Self.disabledItem("Cost (Month-to-Date)")
        title.attributedTitle = NSAttributedString(string: "Cost (Month-to-Date)", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)])
        menu.addItem(title)

        let total = vm.combinedSpendCents
        let pct = Int((UsageMath.spendFraction(usedCents: total, limitCents: vm.customLimitCents) * 100).rounded())
        menu.addItem(Self.disabledItem(
            "\(UsageMath.formatDollars(total)) spent · \(pct)% of \(UsageMath.formatDollars(vm.customLimitCents))"))

        for p in vm.providers {
            if let spend = p.snapshot?.spend {
                menu.addItem(Self.disabledItem("  \(spend.label): \(UsageMath.formatDollars(spend.usedCents))"))
            }
        }
        addRecentPeak(points: vm.spendSeries, unit: .dollars)

        let setLimit = NSMenuItem(title: "Set Custom Cost Total…", action: #selector(setCustomLimit), keyEquivalent: "")
        setLimit.target = self
        menu.addItem(setLimit)
    }

    private func addFooter(now: Date) {
        if let updated = vm.latestUpdate {
            menu.addItem(Self.disabledItem(
                "Updated \(UsageMath.formatClockTime(updated)) · \(UsageMath.formatAgo(since: updated, now: now))"))
        } else if !vm.providers.isEmpty {
            // Providers enabled but nothing fetched yet. With none enabled there's
            // nothing to update, so show nothing.
            menu.addItem(Self.disabledItem("Updating…"))
        }

        let providers = NSMenuItem(title: "Providers", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for id in ProviderID.allCases {
            let item = NSMenuItem(title: Self.displayNames[id] ?? id.rawValue,
                                  action: #selector(toggleProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            item.state = vm.providers.contains { $0.id == id } ? .on : .off
            sub.addItem(item)
        }
        providers.submenu = sub
        menu.addItem(providers)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (launchAtLoginState?() ?? false) ? .on : .off
        menu.addItem(login)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let restart = NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Row text

    private func usageLine(_ window: UsageWindow, at: Date) -> String {
        let pct = Int(window.utilization.rounded())
        if let proj = UsageMath.projectUsage(window, now: at) {
            return "\(pct)% used  ·  projected \(Int(proj.rounded()))%"
        }
        return "\(pct)% used"
    }

    private func resetLine(_ window: UsageWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return "Not started — resets once used" }
        if resetsAt.timeIntervalSince(now) <= 0 { return "Resets soon" }
        return "Resets \(UsageMath.formatResetTime(resetsAt, now: now))  ·  in \(UsageMath.formatDelta(to: resetsAt, now: now))"
    }

    private enum RateUnit { case percent, dollars }

    /// Add a recent-peak line for a cumulative series (the sparkline itself now lives
    /// in the header column). No-op without enough points for a rate.
    private func addRecentPeak(points: [(Date, Double)], unit: RateUnit) {
        guard let peak = UsageMath.peakRatePerMinute(points) else { return }
        menu.addItem(Self.disabledItem(
            "Recent peak: \(formatRate(peak.perMinute, unit: unit))/min @ \(UsageMath.formatClockCompact(peak.at))"))
    }

    private func formatRate(_ perMinute: Double, unit: RateUnit) -> String {
        switch unit {
        case .percent: return "\(UsageMath.trimmed(perMinute, maxFractionDigits: 2))%"
        case .dollars: return String(format: "$%.2f", perMinute / 100)
        }
    }

    // MARK: - Actions

    @objc private func refresh() { onRefresh?() }
    @objc private func restart() { onRestart?() }
    @objc private func toggleLaunchAtLogin() { _ = onToggleLaunchAtLogin?() }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ProviderID(rawValue: raw) else { return }
        onSetProvider?(id, sender.state != .on)
    }

    @objc private func copyError(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        Log.log("copied error to clipboard")
    }

    /// Prompt for the combined cost total (a dollar amount), persist it, and repaint.
    @objc private func setCustomLimit() {
        let alert = NSAlert()
        alert.messageText = "Set Custom Cost Total"
        alert.informativeText = "Enter the dollar amount the combined cost pie fills against."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%.2f", vm.customLimitCents / 100)
        field.placeholderString = "e.g. 2500.00"
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cleaned = field.stringValue
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let dollars = Double(cleaned), dollars > 0, dollars.isFinite else {
            let err = NSAlert()
            err.messageText = "Invalid amount"
            err.informativeText = "Please enter a positive dollar amount, e.g. 2500 or 2499.95."
            NSApp.activate(ignoringOtherApps: true)
            err.runModal()
            return
        }
        Settings.customLimitCents = (dollars * 100).rounded()
        vm.customLimitCents = Settings.customLimitCents
        Log.log("cost: custom total set to \(UsageMath.formatDollars(Settings.customLimitCents))")
        rebuildMenu(now: Date())
        redraw(now: Date())
    }

    // MARK: - Helpers

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
