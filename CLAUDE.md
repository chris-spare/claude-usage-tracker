# AI Spend Tracker

A macOS menu-bar app (pure AppKit, SwiftPM, no external deps) that charts per-provider
AI coding-tool usage and spend (Claude, Codex, Cursor). Targets macOS 13+.

## Common commands

```bash
swift build && swift test          # build + run tests
./scripts/make-app.sh              # build + package the local debug app bundle
open "build/AI Spend Tracker.app"  # run it
```

## Releasing

To cut and publish a new version — a universal, Developer ID–signed, Apple-notarized
GitHub Release — follow **[docs/RELEASING.md](docs/RELEASING.md)**. It's a complete
runbook: one-time cert/notary setup, version bump, `./scripts/make-release.sh`,
verification, and `gh release create`. The build mechanics live in
`scripts/make-release.sh`; don't hand-run the signing steps.
