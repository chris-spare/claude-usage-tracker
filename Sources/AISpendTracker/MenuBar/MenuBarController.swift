import AppKit

/// Owns the menu-bar status item (the donut charts) and the details dropdown. The
/// menu is rebuilt from the current `TrayViewModel`: an app title, the big rings
/// header (which now carries all the per-window detail), a status line only for
/// providers that errored or haven't fetched, a combined spend section, then the
/// footer (Providers submenu, Open at Login / Refresh / Restart / Quit). Each header
/// column carries its own "Updated: …" age; clicking a provider's copies its last raw
/// response.
///
/// The tray image and header render the **snapshot as of each provider's last
/// fetch** (see `PieChart.circles`), so the time arc isn't misrepresented by drift;
/// only the reset countdowns tick against the live clock (refreshed on menu open).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let ringsHeader = RingsHeaderView(frame: NSRect(x: 0, y: 0, width: 220, height: 82))
    /// Repaints the tray when the menu bar flips between light and dark (see `redraw`).
    private var appearanceObserver: NSKeyValueObservation?

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
        // Repaint the tray when the menu bar flips light/dark so the pie hairline stays
        // legible against the bar. effectiveAppearance changes fire on the main thread.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.redraw(now: Date()) }
        }
        ringsHeader.onCopyRawResponse = { [weak self] raw in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(raw, forType: .string)
            Log.log("copied last raw response to clipboard (\(raw.count) chars)")
            self?.menu.cancelTracking()
        }
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

    // MARK: - Menu-bar visibility

    /// Guards the heads-up to once per launch (the user asked for one-time-per-startup).
    private var hasWarnedNotDisplayed = false

    /// macOS silently drops status items that don't fit — common on notched Macs and
    /// crowded menu bars. The button still exists, but its window is parked off-screen.
    /// If it looks like we didn't get a slot, show a one-time (per launch) heads-up
    /// pointing at a menu-bar organizer. Runs on a delay so AppKit has laid out the bar
    /// and the window server has run a display pass before we judge; re-checks once more
    /// before alerting, since layout can still be settling right after launch.
    func warnIfNotDisplayed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.hasWarnedNotDisplayed, !self.statusItemAppearsOnScreen() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.hasWarnedNotDisplayed, !self.statusItemAppearsOnScreen() else { return }
                self.hasWarnedNotDisplayed = true
                self.showNotDisplayedAlert()
            }
        }
    }

    /// Best-effort check that our menu-bar item actually got a slot in a menu bar. A
    /// placed item's button window sits within some screen's frame; a dropped one is
    /// parked off every screen. We decide purely on that intersection (very low chance
    /// of a false "hidden"); occlusion/screen are logged only to diagnose the real case.
    private func statusItemAppearsOnScreen() -> Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else {
            Log.log("visibility: no status-item button window — treating as not displayed")
            return false
        }
        let frame = window.frame
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
        let occludedVisible = window.occlusionState.contains(.visible)
        Log.log("visibility: frame=\(frame) onScreen=\(onScreen) hasScreen=\(window.screen != nil) occlusionVisible=\(occludedVisible)")
        return onScreen
    }

    private func showNotDisplayedAlert() {
        Log.log("visibility: menu-bar item appears hidden — showing heads-up")
        let alert = NSAlert()
        alert.messageText = "AI Spend Tracker may be hidden"
        alert.informativeText = "The app is running, but there wasn't enough room in your menu bar to "
            + "show its icon — common on Macs with a notch or a crowded menu bar.\n\n"
            + "A free menu-bar organizer like Ice can reveal hidden icons and give them room."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Get Ice…")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let url = URL(string: "https://icemenubar.app") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Repaint the tray icon from the current view model. The provider pies are always
    /// drawn as the button image; combined spend follows `spendDisplayMode` — a pie in
    /// the image (`.circle`), a pace-colored dollar title beside it (`.text`), or
    /// nothing (`.off`).
    private func redraw(now: Date) {
        guard let button = statusItem.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let circles = PieChart.circles(from: vm, now: now, includeSpend: vm.spendDisplayMode == .circle)
        let title = spendTitle(now: now, isDark: isDark)

        // Everything is composited into the single button image (pies, then the spend
        // text in `.text` mode), so we control the spacing exactly — a small left gap
        // before the text and no trailing padding. Using the button's own title instead
        // would add an uncontrollable gap and a right margin.
        button.image = composeTrayImage(circles: circles, title: title, outline: PieChart.outline(forDark: isDark))
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")

        let errored = vm.providers.filter { $0.error != nil }.map(\.displayName)
        button.image?.accessibilityDescription = errored.isEmpty
            ? "AI usage across \(vm.providers.count) provider(s)"
            : "AI usage — fetch failed for: \(errored.joined(separator: ", "))"
    }

    /// Left gap between the provider pies and the spend text in `.text` mode. There is
    /// deliberately no matching right margin — the image ends flush with the text.
    private static let spendTextLeftMargin: CGFloat = 6

    /// The final tray image: the provider pies, plus the spend dollar text laid out to
    /// their right when `title` is set. When there are pies the text is offset by
    /// `spendTextLeftMargin`; the image's right edge sits flush against the text (no
    /// trailing padding). With no title this is just the pies (or the empty-ring
    /// placeholder when nothing is enabled).
    private func composeTrayImage(circles: [PieChart.Circle], title: NSAttributedString?,
                                  outline: NSColor) -> NSImage {
        guard let title else { return PieChart.image(circles: circles, outline: outline) }

        // Only draw the pies when there are real circles — otherwise the placeholder
        // ring would sit as a stray dot beside the text.
        let pies = circles.isEmpty ? nil : PieChart.image(circles: circles, outline: outline)
        let piesSize = pies?.size ?? .zero
        let textSize = title.size()
        let textWidth = ceil(textSize.width)
        let width = piesSize.width + Self.spendTextLeftMargin + textWidth
        let height = max(piesSize.height, ceil(textSize.height))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let pies {
                pies.draw(at: NSPoint(x: 0, y: (height - piesSize.height) / 2),
                          from: .zero, operation: .sourceOver, fraction: 1)
            }
            title.draw(at: NSPoint(x: piesSize.width + Self.spendTextLeftMargin,
                                   y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false   // keep the pace color, not a monochrome template
        return image
    }

    /// The combined-spend dollar figure for the menu bar, colored by pace, or nil when
    /// spend isn't shown as text (or there's no spend yet). Neutral is adaptive — white
    /// on a dark bar, dark on a light one — so it stays legible either way.
    private func spendTitle(now: Date, isDark: Bool) -> NSAttributedString? {
        guard vm.spendDisplayMode == .text, vm.hasAnySpend else { return nil }
        let cents = vm.combinedSpendCents
        let timeFraction = UsageMath.monthTimeFraction(now: vm.latestUpdate ?? now)
        let status = UsageMath.spendStatus(usedCents: cents, limitCents: vm.customLimitCents, timeFraction: timeFraction)
        // Neutral adapts to the bar (white on dark, dark on light); the alert tints are
        // shared with the dropdown spend column via PieChart.spendStatusColor.
        let color = PieChart.spendStatusColor(status, neutral: NSColor(white: isDark ? 1 : 0, alpha: 1))
        return NSAttributedString(string: UsageMath.formatDollarsRounded(cents), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: color])
    }

    // Refresh countdowns/ago against the live clock each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(now: Date())
    }

    // MARK: - Menu construction

    private func rebuildMenu(now: Date) {
        menu.removeAllItems()

        let title = Self.disabledItem("AI Spend Tracker")
        title.attributedTitle = NSAttributedString(string: "AI Spend Tracker", attributes: [
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
            if addProviderStatus(p) { menu.addItem(.separator()) }
        }

        if vm.hasAnySpend { addSpendSection(); menu.addItem(.separator()) }

        addFooter()
    }

    /// A status line for a provider that isn't drawing healthy columns — an error
    /// (message + Copy Error), "No data yet", or a plan with no usage window. Healthy
    /// providers show nothing here (all their detail lives in the rings header).
    /// Returns whether anything was added (so the caller can place a separator).
    @discardableResult
    private func addProviderStatus(_ p: ProviderView) -> Bool {
        if let error = p.error {
            addProviderTitle(p)
            let msg = Self.disabledItem(error)
            msg.attributedTitle = NSAttributedString(string: error, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(msg)
            let copy = NSMenuItem(title: "Copy Error", action: #selector(copyError(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = error
            menu.addItem(copy)
            return true
        }
        guard let snap = p.snapshot else {
            addProviderTitle(p)
            menu.addItem(Self.disabledItem("No data yet"))   // enabled, not fetched yet
            return true
        }
        guard !snap.windows.isEmpty else {
            // Fetched fine, but this plan exposes no rate-limit window (e.g. a
            // usage-based account) — so there's no circle to draw for it.
            addProviderTitle(p)
            menu.addItem(Self.disabledItem("No usage window on this plan"))
            return true
        }
        return false   // healthy — everything's in the rings header columns
    }

    /// The provider's name as a colored, bold section title.
    private func addProviderTitle(_ p: ProviderView) {
        let titleItem = Self.disabledItem(p.displayName)
        titleItem.attributedTitle = NSAttributedString(string: p.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
            .foregroundColor: PieChart.palette(for: p.id).usage])
        menu.addItem(titleItem)
    }

    /// The combined spend readout: total spent (against the budget, when one is set)
    /// and the per-provider breakdown. The controls (display mode, Set Budget) live in
    /// the always-reachable footer "Spend" submenu instead.
    private func addSpendSection() {
        let title = Self.disabledItem("Spend (Month-to-Date)")
        title.attributedTitle = NSAttributedString(string: "Spend (Month-to-Date)", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)])
        menu.addItem(title)

        let total = vm.combinedSpendCents
        let summary: String
        if vm.customLimitCents > 0 {
            let pct = Int((UsageMath.spendFraction(usedCents: total, limitCents: vm.customLimitCents) * 100).rounded())
            summary = "\(UsageMath.formatDollars(total)) spent · \(pct)% of \(UsageMath.formatDollars(vm.customLimitCents))"
        } else {
            summary = "\(UsageMath.formatDollars(total)) spent · no budget set"
        }
        menu.addItem(Self.disabledItem(summary))

        for p in vm.providers {
            if let spend = p.snapshot?.spend {
                menu.addItem(Self.disabledItem("  \(spend.label): \(UsageMath.formatDollars(spend.usedCents))"))
            }
        }
    }

    private func addFooter() {
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

        addSpendSubmenu()

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

    /// The always-reachable "Spend" submenu: a Ring/Text/Off radio group for how spend
    /// shows in the bar, then "Set Spend Budget…". Present even before any spend
    /// arrives, so the mode can be pre-set.
    private func addSpendSubmenu() {
        let spend = NSMenuItem(title: "Spend", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (mode, label) in Self.spendDisplayLabels {
            let item = NSMenuItem(title: label, action: #selector(setSpendDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = vm.spendDisplayMode == mode ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let setLimit = NSMenuItem(title: "Set Spend Budget…", action: #selector(setCustomLimit), keyEquivalent: "")
        setLimit.target = self
        sub.addItem(setLimit)
        spend.submenu = sub
        menu.addItem(spend)
    }

    /// Radio labels for the spend display modes, in menu order.
    private static let spendDisplayLabels: [(SpendDisplayMode, String)] = [
        (.circle, "Ring"), (.text, "Text"), (.off, "Off"),
    ]

    // MARK: - Actions

    @objc private func refresh() { onRefresh?() }
    @objc private func restart() { onRestart?() }
    @objc private func toggleLaunchAtLogin() { _ = onToggleLaunchAtLogin?() }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ProviderID(rawValue: raw) else { return }
        onSetProvider?(id, sender.state != .on)
    }

    /// Switch how spend renders in the bar, persist it, and repaint.
    @objc private func setSpendDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SpendDisplayMode(rawValue: raw) else { return }
        Settings.spendDisplayMode = mode
        vm.spendDisplayMode = mode
        Log.log("spend: display mode = \(mode.rawValue)")
        rebuildMenu(now: Date())
        redraw(now: Date())
    }

    @objc private func copyError(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        Log.log("copied error to clipboard")
    }

    /// Prompt for the combined spend total (a dollar amount), persist it, and repaint.
    @objc private func setCustomLimit() {
        let alert = NSAlert()
        alert.messageText = "Set Spend Budget"
        alert.informativeText = "Enter the dollar amount the combined spend pie fills toward. "
            + "Enter 0 for no budget — the ring then just flags any spend at all (empty at $0, full above)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%.2f", vm.customLimitCents / 100)
        field.placeholderString = "e.g. 2500.00 (or 0 for none)"
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
        guard let dollars = Double(cleaned), dollars >= 0, dollars.isFinite else {
            let err = NSAlert()
            err.messageText = "Invalid amount"
            err.informativeText = "Please enter a dollar amount of 0 or more, e.g. 2500, 2499.95, or 0."
            NSApp.activate(ignoringOtherApps: true)
            err.runModal()
            return
        }
        Settings.customLimitCents = (dollars * 100).rounded()
        vm.customLimitCents = Settings.customLimitCents
        Log.log("spend: budget set to \(UsageMath.formatDollars(Settings.customLimitCents))")
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
