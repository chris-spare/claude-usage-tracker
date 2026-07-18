# Releasing

How to cut a new version: a **universal** (Intel + Apple Silicon), Developer ID–signed,
Apple-notarized, stapled `.app`, published as a GitHub Release. Runs on macOS 13
(Ventura) and later.

The build/sign/notarize/staple mechanics live in [`scripts/make-release.sh`](../scripts/make-release.sh).
This runbook covers the whole flow around it, so a fresh agent (or a fresh machine)
can repeat it end to end.

Key constants:

- **Team ID:** `7H2524M5TN`
- **Notary keychain profile:** `claude-usage-notary`
- **GitHub repo:** `chris-spare/claude-usage-tracker`
- App / bundle / zip names come from `Resources/Info.plist` and `scripts/make-release.sh`
  (they've been renamed before). The commands below use the current names; if it's
  renamed again, the script prints the exact output paths.

## One-time setup (per machine)

Only needed once on a given Mac. Skip if both of these already work:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"   # prints an identity
xcrun notarytool history --keychain-profile claude-usage-notary              # succeeds (not an auth error)
```

Otherwise:

1. **Developer ID Application certificate** — needs an Apple Developer Program
   membership ($99/yr). In Xcode → Settings → Accounts → your Apple ID →
   **Manage Certificates…** → **+** → **Developer ID Application**.
   - If Apple returns *"Unable to process request — PLA Update available"*, accept the
     latest agreement at <https://developer.apple.com/account> (Membership/Agreements),
     wait a minute, then retry.

2. **Notarization credentials** stored under the `claude-usage-notary` profile:
   - Create an app-specific password at <https://appleid.apple.com> → Sign-In &
     Security → **App-Specific Passwords**.
   - Store it (paste the password at the hidden prompt):
     ```bash
     xcrun notarytool store-credentials "claude-usage-notary" \
       --apple-id "<your-apple-id-email>" --team-id 7H2524M5TN
     ```

## Cutting a release

Precondition: your code changes are already committed and pushed to `main`, and
`git status` is clean.

1. **Bump the version.** In `Resources/Info.plist`, increment `CFBundleShortVersionString`
   (e.g. `0.2.1` → `0.2.2`) and `CFBundleVersion` (integer, +1). Commit and push:
   ```bash
   git add Resources/Info.plist
   git commit -m "Bump version to X.Y.Z"
   git push origin main
   ```

2. **Build + notarize + staple:**
   ```bash
   ./scripts/make-release.sh
   ```
   It builds the universal binary, signs with Developer ID, submits to Apple, waits
   for notarization, staples, and writes the distributable zip — printing its path at
   the end (`distributable: build/…zip`).
   - **Notarization time is Apple-side and varies:** usually a few minutes,
     occasionally 30–60 min when their queue is backed up. The script just waits.
   - **Don't run a debug build (`make-app.sh`) while this is in flight.** The release
     builds into `build/release/` to avoid a collision, and aborts if the signed
     bundle changes before stapling.

3. **Verify the artifact** (the script checks internally; confirm independently if you like):
   ```bash
   APP="build/release/AI Spend Tracker.app"   # or whatever the script printed
   lipo -archs "$APP/Contents/MacOS/"*        # expect: x86_64 arm64
   xcrun stapler validate "$APP"              # expect: The validate action worked!
   spctl -a -vvv -t install "$APP"            # expect: accepted / source=Notarized Developer ID
   ```

4. **Publish the GitHub Release.** Tag `vX.Y.Z` matches the version; attach the zip the
   script produced. Keep older releases — don't delete them.
   ```bash
   gh release create vX.Y.Z \
     "build/AISpendTracker.zip#AI Spend Tracker.app (universal, notarized)" \
     --repo chris-spare/claude-usage-tracker \
     --target main \
     --title "AI Spend Tracker vX.Y.Z" \
     --notes "What changed, plus install steps."
   ```

5. **Confirm the asset uploaded:**
   ```bash
   gh release view vX.Y.Z --repo chris-spare/claude-usage-tracker \
     --json assets --jq '.assets[] | {name, state}'
   ```

## Installing on another Mac

Download the zip from the release → unzip → drag the `.app` into `/Applications` →
open it (first launch shows a one-time *"downloaded from the internet → Open"*).
It's stapled, so it also verifies offline.

## Gotchas

- **Stapling fails with "Record not found" right after acceptance** — Apple's ticket
  CDN is lagging. The script retries for ~20 min. If it still fails, notarization
  itself already succeeded; just re-run `xcrun stapler staple "<app>"` a few minutes
  later, then re-zip.
- **`spctl`/Gatekeeper rejects the app on the other Mac** — it wasn't notarized or
  wasn't stapled. Re-run the release; don't hand-sign around it.
