// swift-tools-version:6.2
// Apple Reminders MCP: an MCP server for Apple Reminders that writes through the private
// ReminderKit framework, so everything Reminders offers (flags, tags, subtasks, urgent alerts,
// repeats, sections, groups, smart lists, attachments, location and early alerts) is native and
// syncs through iCloud.
import PackageDescription

let package = Package(
    name: "AppleRemindersMCP",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "Wire"),
        .target(name: "Launcher"),
        .target(name: "ReminderKitShim"),
        .executableTarget(name: "AppleRemindersMCP", dependencies: ["Wire", "Launcher", "ReminderKitShim"]),
    ]
)
