// swift-tools-version:6.2
// Apple Notes MCP and Apple Reminders MCP: MCP servers that let AI agents read and write Apple Notes
// and Apple Reminders natively, built from one package. Each app keeps its own name, command,
// permissions and executable; the shared base is Wire (MCP over stdio, the command line's flags,
// the choice of tools), Launcher (holding the app's own privacy permissions) and Agents (finding
// AI agents and setting them up). See docs/MERGE-PLAN.md.
//
// Notes reads through Notes' own data model and edits in place through its private NotesShared
// framework (NotesShim, NoteModel). Reminders writes through the private ReminderKit framework
// (ReminderKitShim). Both stay native and sync through iCloud.
import PackageDescription

let package = Package(
    name: "AppleMCP",
    platforms: [.macOS(.v26)],
    targets: [
        // The shared base.
        .target(name: "Wire"),
        .target(name: "Launcher"),
        .target(name: "Agents", dependencies: ["Launcher"]),

        // Apple Notes MCP.
        .target(name: "NotesShim"),
        .target(name: "NoteModel"),
        .executableTarget(name: "AppleNotesMCP", dependencies: ["Wire", "Launcher", "NotesShim", "NoteModel", "Agents"]),

        // Apple Reminders MCP.
        .target(name: "ReminderKitShim"),
        .executableTarget(name: "AppleRemindersMCP", dependencies: ["Wire", "Launcher", "ReminderKitShim", "Agents"]),

        .testTarget(name: "AgentsTests", dependencies: ["Agents"]),
        .testTarget(name: "WireTests", dependencies: ["Wire"]),
        .testTarget(name: "NoteModelTests", dependencies: ["NoteModel"]),
    ]
)
