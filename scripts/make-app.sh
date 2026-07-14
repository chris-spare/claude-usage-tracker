#!/usr/bin/env bash
# Build "Claude Usage.app" — a menu-bar accessory bundle around the SwiftPM
# executable. Signed with a real identity when available (stable designated
# requirement → TCC/Keychain grants persist across rebuilds), else ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"

echo "building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ClaudeUsageTray"

APP="build/Claude Usage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsageTray"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    echo "signing as: $IDENTITY"
    codesign --force --sign "$IDENTITY" --identifier com.chriswa.claudeusagetracker \
        --entitlements Resources/ClaudeUsageTray.entitlements --options runtime "$APP"
else
    echo "signing ad-hoc (no identity found — Keychain grants won't persist across rebuilds)"
    codesign --force --sign - --identifier com.chriswa.claudeusagetracker \
        --entitlements Resources/ClaudeUsageTray.entitlements "$APP"
fi

echo "built: $APP"
echo "run:   open \"$APP\"    (or: \"$APP/Contents/MacOS/ClaudeUsageTray\" for logs)"
