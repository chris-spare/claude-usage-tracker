# Claude Usage Tracker

A macOS menu-bar app that charts your Claude Code usage as three donut circles —
the **5-hour** and **7-day** rate-limit windows plus **month-to-date spend** —
each labeled in its center (`5h`, `7d`, `$`).

![Claude Usage Tracker menu](docs/screenshot.png)

Every donut overlays two clockwise arcs from 12 o'clock — elapsed *time* and
*usage* — colored by how they compare:

- **yellow** where they overlap,
- **blue** when you're under pace (more time elapsed than usage),
- **red** when over pace (usage ahead of time),
- **black** remainder, with a thin white ring.

For the two windows, "time" is how far into the window you are; for spend it's how
far through the calendar month, and "usage" is dollars against your limit.

Click the icon for exact numbers per section — current % + projected
end-of-window % + reset time for the windows, dollars spent + limit for spend —
plus a 2-hour **usage-rate sparkline** (per-fetch deltas, so it spikes during
bursts and rests at zero when idle) and a **recent-peak** readout, and when it
last refreshed. If the last fetch failed, a ⚠︎ warning glyph joins the circles and
the error is shown at the top of the menu.

### Custom spend limit

The spend circle uses the API-supplied monthly limit by default. To override it,
open the menu → **Set Custom Limit…**, enter a dollar amount, and it's used
instead (the menu then shows both your custom limit and the API limit). **Clear
Custom Limit** reverts to the API value.

## Install

Runs on **macOS 13 (Ventura) or later**, on both Apple Silicon and Intel Macs.

1. Download `ClaudeUsage.zip` from the [latest release](../../releases/latest).
2. Unzip it and drag **Claude Usage.app** into `/Applications`.
3. Open it. It's signed and notarized by Apple, so it launches without warnings
   (on first open macOS confirms it was downloaded from the internet — click
   **Open**).

## Building from source

Requires macOS 13+ and the Swift toolchain (install Xcode or the Command Line
Tools: `xcode-select --install`).

```bash
# 1. Build and package the app bundle (compiles, bundles, and codesigns).
./scripts/make-app.sh

# 2. Launch it.
open "build/Claude Usage.app"
```

The donuts appear in your menu bar. The first time it fetches, macOS may ask
permission to read the **“Claude Code-credentials”** Keychain item — click
**Always Allow**. That's the OAuth token it uses to read your usage; the app only
reads it, and only talks to `api.anthropic.com`.

To stop it: click the icon → **Quit**.

### Open at Login

It's **on by default** — the app registers itself as a login item the first time
it runs, so it comes back after a reboot. You can toggle it any time from the menu
(**Open at Login**); your choice sticks.

## Building a release

`./scripts/make-release.sh` produces the distributable artifact: a universal
(arm64 + x86_64) build, signed with a Developer ID Application certificate under
a hardened runtime, notarized by Apple, and stapled. Output is
`build/ClaudeUsage.zip` — attach it to a GitHub Release.

One-time setup:

1. A **Developer ID Application** certificate in your login Keychain (Xcode →
   Settings → Accounts → Manage Certificates → **+**). Requires an Apple
   Developer Program membership.
2. Notarization credentials stored under a keychain profile:

   ```bash
   xcrun notarytool store-credentials "claude-usage-notary" \
     --apple-id "you@example.com" --team-id <YOUR_TEAM_ID>
   ```

   (Uses an [app-specific password](https://appleid.apple.com).) Override the
   profile name with `NOTARY_PROFILE=… ./scripts/make-release.sh` if you use a
   different one.

## Notes

- Usage is fetched at most **once every 5 minutes**. The last fetch time and
  reading are cached to disk, so restarting the app doesn't trigger an extra API
  call within that window — it reuses the cache and waits out the rest of the
  cooldown. The donuts show that last snapshot: the time arc does **not** creep
  between fetches (which would misrepresent usage-vs-time). Only the menu's reset
  countdown and "updated … ago" text advance with the clock, refreshed each time
  you open the menu.
- Requires a **Claude.ai subscription** account (Pro/Team/etc.). API-key-only
  accounts have no usage endpoint, so the app will note that and stop polling.
- Runtime log: `~/Library/Logs/ClaudeUsageTray.log`.
- Tests: `swift test`. Preview render: `swift run ClaudeUsageTray --render /tmp/preview.png`.
