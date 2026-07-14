// swift-tools-version: 6.0
import PackageDescription

// Claude Usage Tray — a macOS menu-bar app that shows two pie charts (5-hour and
// 7-day Claude Code usage) and a details menu. Pure AppKit, no external deps.
let package = Package(
    name: "ClaudeUsageTray",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ClaudeUsageTray",
            path: "Sources/ClaudeUsageTray"
        ),
        .testTarget(
            name: "ClaudeUsageTrayTests",
            dependencies: ["ClaudeUsageTray"],
            path: "Tests/ClaudeUsageTrayTests"
        ),
    ]
)
