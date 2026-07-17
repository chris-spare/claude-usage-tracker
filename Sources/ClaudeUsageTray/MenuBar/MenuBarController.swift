import AppKit

/// Owns the menu-bar status item (the donut charts) and the details dropdown.
/// Top to bottom the menu shows: an error section (only when the last fetch
/// failed), the 5-hour / 7-day / spend sections, the last-updated line, then
/// Open at Login / Refresh / Restart / Quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // App title (always at the very top).
    private let appTitle = MenuBarController.disabledItem("Claude Usage Tracker")

    // Large side-by-side rings with captions, just under the title.
    private let ringsHeader = RingsHeaderView(frame: NSRect(x: 0, y: 0, width: 220, height: 82))
    private let ringsHeaderItem = MenuBarController.disabledItem("")

    // Error section (top; hidden unless the last fetch failed).
    private let errorTitle = MenuBarController.disabledItem("Fetch Error")
    private let errorMessage = MenuBarController.disabledItem("")
    private let errorSeparator = NSMenuItem.separator()

    // 5-hour section.
    private let fiveHourTitle = MenuBarController.disabledItem("5-Hour")
    private let fiveHourUsage = MenuBarController.disabledItem("")
    private let fiveHourReset = MenuBarController.disabledItem("")
    private let fiveHourSpark = SparklineView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
    private let fiveHourSparkItem = MenuBarController.disabledItem("")
    private let fiveHourPeak = MenuBarController.disabledItem("")
    // 7-day section.
    private let sevenDayTitle = MenuBarController.disabledItem("7-Day")
    private let sevenDayUsage = MenuBarController.disabledItem("")
    private let sevenDayReset = MenuBarController.disabledItem("")
    private let sevenDaySpark = SparklineView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
    private let sevenDaySparkItem = MenuBarController.disabledItem("")
    private let sevenDayPeak = MenuBarController.disabledItem("")
    // Month-to-date spend section.
    private let spendTitle = MenuBarController.disabledItem("Month-to-Date Spend")
    private let spendAmount = MenuBarController.disabledItem("")
    private let spendLimit = MenuBarController.disabledItem("")
    private let spendApiLimit = MenuBarController.disabledItem("")
    private let spendSpark = SparklineView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
    private let spendSparkItem = MenuBarController.disabledItem("")
    private let spendPeak = MenuBarController.disabledItem("")
    private let setLimitItem = NSMenuItem(title: "Set Custom Limit…",
                                          action: #selector(setCustomLimit), keyEquivalent: "")
    private let clearLimitItem = NSMenuItem(title: "Clear Custom Limit",
                                            action: #selector(clearCustomLimit), keyEquivalent: "")

    private let updatedItem = MenuBarController.disabledItem("Updating…")
    private let loginItem = NSMenuItem(title: "Open at Login",
                                       action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    /// Latest data we've been handed, redrawn on a clock tick so the time arcs and
    /// countdowns advance between (infrequent) fetches.
    private var data: ClaudeUsageData?
    /// When the last successful fetch completed (for the "Updated … ago" line).
    private var lastUpdated: Date?
    /// The most recent fetch error, cleared on the next success.
    private var lastError: String?

    var onRefresh: (() -> Void)?
    var onRestart: (() -> Void)?
    var launchAtLoginState: (() -> Bool)?
    var onToggleLaunchAtLogin: (() -> Bool)?
    /// Supplies the rolling usage history that feeds the sparklines (oldest first).
    var historyProvider: (() -> [UsageHistory.Sample])?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        redraw()
    }

    private func buildMenu() {
        menu.delegate = self
        for header in [fiveHourTitle, sevenDayTitle, spendTitle] {
            header.attributedTitle = NSAttributedString(string: header.title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)])
        }
        errorTitle.attributedTitle = NSAttributedString(string: "⚠︎ Fetch Error", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
            .foregroundColor: NSColor.systemRed])
        appTitle.attributedTitle = NSAttributedString(string: appTitle.title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)])

        fiveHourSparkItem.view = fiveHourSpark
        sevenDaySparkItem.view = sevenDaySpark
        spendSparkItem.view = spendSpark

        ringsHeader.setFrameSize(NSSize(width: 220, height: ringsHeader.preferredHeight))
        ringsHeaderItem.view = ringsHeader

        // App title, the big rings, then the error section (shown only on failure).
        menu.addItem(appTitle)
        menu.addItem(.separator())
        menu.addItem(ringsHeaderItem)
        menu.addItem(.separator())
        for item in [errorTitle, errorMessage] { menu.addItem(item) }
        menu.addItem(errorSeparator)
        // Usage sections — the read-outs, then a sparkline, then the recent-peak
        // line at the bottom of each section.
        for item in [fiveHourTitle, fiveHourUsage, fiveHourReset, fiveHourSparkItem, fiveHourPeak] { menu.addItem(item) }
        menu.addItem(.separator())
        for item in [sevenDayTitle, sevenDayUsage, sevenDayReset, sevenDaySparkItem, sevenDayPeak] { menu.addItem(item) }
        menu.addItem(.separator())
        for item in [spendTitle, spendAmount, spendLimit, spendApiLimit, spendSparkItem, spendPeak] { menu.addItem(item) }
        setLimitItem.target = self
        clearLimitItem.target = self
        menu.addItem(setLimitItem)
        menu.addItem(clearLimitItem)
        menu.addItem(.separator())
        // Footer.
        menu.addItem(updatedItem)
        loginItem.target = self
        menu.addItem(loginItem)
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let restart = NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Data in

    /// Hand in data and repaint. `at` is when the fetch happened (now for a live
    /// fetch, or the cached timestamp when restoring on launch). Clears any error.
    func update(data: ClaudeUsageData, at date: Date = Date()) {
        self.data = data
        lastUpdated = date
        lastError = nil
        redraw()
    }

    /// Record a fetch error and repaint so the warning icon appears immediately.
    /// The last good data stays on screen.
    func setError(_ message: String) {
        lastError = message
        redraw()
    }

    /// Repaint the tray icon. The pies render the **snapshot as of the last fetch**
    /// (not the live clock), so the time arc — and thus the time-vs-usage
    /// comparison — isn't misrepresented by up to a fetch interval of drift.
    func redraw() {
        guard let button = statusItem.button else { return }
        let snapshot = lastUpdated ?? Date()
        button.image = PieChart.trayImage(fiveHour: data?.fiveHour, sevenDay: data?.sevenDay,
                                          extraUsage: data?.extraUsage,
                                          customLimitCents: Settings.customLimitCents,
                                          showError: lastError != nil, now: snapshot)
        button.image?.accessibilityDescription = lastError == nil
            ? "Claude usage: 5-hour, 7-day, and month-to-date spend"
            : "Claude usage (last fetch failed): \(lastError ?? "")"
    }

    // MARK: - Menu text (refreshed on open)

    func menuWillOpen(_ menu: NSMenu) {
        let now = Date()
        let snapshot = lastUpdated ?? now   // usage/projection reflect the last fetch
        let hasError = lastError != nil
        for item in [errorTitle, errorMessage] { item.isHidden = !hasError }
        errorSeparator.isHidden = !hasError
        errorMessage.title = lastError ?? ""

        // Big rings mirror the tray image (drawn at the last-fetch snapshot).
        ringsHeader.circles = PieChart.circles(fiveHour: data?.fiveHour, sevenDay: data?.sevenDay,
                                               extraUsage: data?.extraUsage,
                                               customLimitCents: Settings.customLimitCents, now: snapshot)

        applyBucket(bucket: data?.fiveHour, window: UsageWindow.fiveHour,
                    usageItem: fiveHourUsage, resetItem: fiveHourReset, now: now, snapshot: snapshot)
        applyBucket(bucket: data?.sevenDay, window: UsageWindow.sevenDay,
                    usageItem: sevenDayUsage, resetItem: sevenDayReset, now: now, snapshot: snapshot)
        applySpend(data?.extraUsage)

        // Sparklines + recent-peak lines from the rolling history (each hidden
        // until it has ≥2 points).
        let history = historyProvider?() ?? []
        applyMetric(spark: fiveHourSpark, sparkItem: fiveHourSparkItem, peakItem: fiveHourPeak,
                    points: history.compactMap { s in s.fiveHourUtil.map { (s.date, $0) } }, unit: .percent)
        applyMetric(spark: sevenDaySpark, sparkItem: sevenDaySparkItem, peakItem: sevenDayPeak,
                    points: history.compactMap { s in s.sevenDayUtil.map { (s.date, $0) } }, unit: .percent)
        applyMetric(spark: spendSpark, sparkItem: spendSparkItem, peakItem: spendPeak,
                    points: history.compactMap { s in s.spendCents.map { (s.date, $0) } },
                    unit: .dollars, visible: data?.extraUsage != nil)
        if let lastUpdated {
            updatedItem.title = "Updated \(UsageMath.formatClockTime(lastUpdated)) · \(UsageMath.formatAgo(since: lastUpdated, now: now))"
        } else {
            updatedItem.title = "Updating…"
        }
        loginItem.state = (launchAtLoginState?() ?? false) ? .on : .off
    }

    private enum RateUnit { case percent, dollars }

    /// Feed a section's sparkline (raw cumulative series) and its recent-peak line
    /// (peak per-minute rate + time). Rows hide when there's too little data or the
    /// section is hidden.
    private func applyMetric(spark: SparklineView, sparkItem: NSMenuItem, peakItem: NSMenuItem,
                             points: [(Date, Double)], unit: RateUnit, visible: Bool = true) {
        spark.samples = points
        sparkItem.isHidden = !visible || points.count < 2
        if visible, let peak = UsageMath.peakRatePerMinute(points) {
            peakItem.isHidden = false
            peakItem.title = "Recent peak: \(formatRate(peak.perMinute, unit: unit))/min @ \(UsageMath.formatClockCompact(peak.at))"
        } else {
            peakItem.isHidden = true
        }
    }

    private func formatRate(_ perMinute: Double, unit: RateUnit) -> String {
        switch unit {
        case .percent: return "\(UsageMath.trimmed(perMinute, maxFractionDigits: 2))%"
        case .dollars: return String(format: "$%.2f", perMinute / 100)   // perMinute is cents/min
        }
    }

    /// `snapshot` is the last-fetch time (usage % + projection are of that moment);
    /// `now` is the live clock (only the reset countdown ticks against it).
    private func applyBucket(bucket: UsageBucket?, window: TimeInterval,
                             usageItem: NSMenuItem, resetItem: NSMenuItem, now: Date, snapshot: Date) {
        guard let bucket else {
            usageItem.title = "No data yet"
            resetItem.isHidden = true
            return
        }
        let pct = Int(bucket.utilization.rounded())
        if let proj = UsageMath.projectUsage(utilization: bucket.utilization,
                                             resetsAt: bucket.resetsAt, window: window, now: snapshot) {
            usageItem.title = "\(pct)% used  ·  projected \(Int(proj.rounded()))%"
        } else {
            usageItem.title = "\(pct)% used"
        }
        // An idle window (no reset scheduled yet) has no countdown to show.
        guard let resetsAt = bucket.resetsAt else {
            resetItem.isHidden = false
            resetItem.title = "Not started — resets once used"
            return
        }
        resetItem.isHidden = false
        // Genuine wall-clock countdown; once the window is past due (before the next
        // fetch brings a fresh window) say "Resets soon" rather than a negative time.
        if resetsAt.timeIntervalSince(now) <= 0 {
            resetItem.title = "Resets soon"
        } else {
            let reset = UsageMath.formatResetTime(resetsAt, now: now)
            let delta = UsageMath.formatDelta(to: resetsAt, now: now)
            resetItem.title = "Resets \(reset)  ·  in \(delta)"
        }
    }

    /// Populate (or hide) the month-to-date spend section, honoring a custom limit.
    private func applySpend(_ extra: ExtraUsage?) {
        let custom = Settings.customLimitCents
        let visible = extra != nil
        for item in [spendTitle, spendAmount, spendLimit] { item.isHidden = !visible }
        setLimitItem.isHidden = !visible
        clearLimitItem.isHidden = !visible
        clearLimitItem.isEnabled = custom != nil
        // The API limit line is only interesting when a custom one overrides it.
        spendApiLimit.isHidden = !(visible && custom != nil)

        guard let extra else { return }
        spendAmount.title = "\(UsageMath.formatDollars(extra.usedCents)) spent this month"
        if let custom {
            let pct = Int(UsageMath.spendFraction(extra, customLimitCents: custom) * 100 + 0.5)
            spendLimit.title = "Custom limit \(UsageMath.formatDollars(custom))  ·  \(pct)%"
            spendApiLimit.title = extra.monthlyLimitCents
                .map { "API limit \(UsageMath.formatDollars($0))" } ?? "API limit: none"
        } else if let limit = extra.monthlyLimitCents {
            let pct = Int(UsageMath.spendFraction(extra) * 100 + 0.5)
            spendLimit.title = "Limit \(UsageMath.formatDollars(limit))  ·  \(pct)%"
        } else {
            spendLimit.title = "No monthly limit set"
        }
    }

    // MARK: - Actions

    @objc private func refresh() { onRefresh?() }
    @objc private func restart() { onRestart?() }
    @objc private func toggleLaunchAtLogin() {
        loginItem.state = (onToggleLaunchAtLogin?() ?? false) ? .on : .off
    }

    /// Prompt for a custom monthly spend limit (a dollar amount). Validates a
    /// money-like number, persists it, and repaints.
    @objc private func setCustomLimit() {
        let alert = NSAlert()
        alert.messageText = "Set Custom Monthly Limit"
        alert.informativeText = "Enter a dollar amount to use for the spend circle instead of the API-supplied limit."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = Settings.customLimitCents.map { String(format: "%.2f", $0 / 100) } ?? ""
        field.placeholderString = "e.g. 500.00"
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)   // accessory app: bring the alert forward
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let cleaned = field.stringValue
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let dollars = Double(cleaned), dollars > 0, dollars.isFinite else {
            let err = NSAlert()
            err.messageText = "Invalid amount"
            err.informativeText = "Please enter a positive dollar amount, e.g. 500 or 499.95."
            NSApp.activate(ignoringOtherApps: true)
            err.runModal()
            return
        }
        Settings.customLimitCents = (dollars * 100).rounded()
        Log.log("spend: custom limit set to \(UsageMath.formatDollars(dollars * 100))")
        redraw()
    }

    @objc private func clearCustomLimit() {
        Settings.customLimitCents = nil
        Log.log("spend: custom limit cleared")
        redraw()
    }

    // MARK: - Helpers

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
