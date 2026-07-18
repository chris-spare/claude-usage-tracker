// swift-tools-version: 6.0
import PackageDescription

// AI Usage Tracker — a macOS menu-bar app showing per-provider usage pie charts
// (Claude, Codex, Cursor) and a details menu. Pure AppKit, no external deps.
let package = Package(
    name: "AIUsageTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AIUsageTracker",
            path: "Sources/AIUsageTracker"
        ),
        .testTarget(
            name: "AIUsageTrackerTests",
            dependencies: ["AIUsageTracker"],
            path: "Tests/AIUsageTrackerTests"
        ),
    ]
)
