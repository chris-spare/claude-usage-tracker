// swift-tools-version: 6.0
import PackageDescription

// AI Spend Tracker — a macOS menu-bar app showing per-provider usage pie charts
// (Claude, Codex, Cursor) and a details menu. Pure AppKit, no external deps.
let package = Package(
    name: "AISpendTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AISpendTracker",
            path: "Sources/AISpendTracker"
        ),
        .testTarget(
            name: "AISpendTrackerTests",
            dependencies: ["AISpendTracker"],
            path: "Tests/AISpendTrackerTests"
        ),
    ]
)
