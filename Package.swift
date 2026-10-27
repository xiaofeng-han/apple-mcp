// swift-tools-version:6.2
// Apple Notes MCP and Apple Reminders MCP: MCP servers that let AI agents read and write Apple Notes
// and Apple Reminders natively, built from one package. Each app keeps its own name, command,
// permissions and executable (a main.swift of one line); the shared base is Wire (MCP over stdio,
// the command line's flags, the choice of tools), Launcher (holding the app's own privacy
// permissions), Agents (finding AI agents and setting them up) and AppCore (the modes, the command
// line, the settings window). Each app's own code is a component (NotesComponent,
// RemindersComponent) that AppCore runs. See docs/MERGE-PLAN.md.
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
        .target(name: "AppCore", dependencies: ["Wire", "Launcher", "Agents"]),

        // Apple Notes MCP.
        .target(name: "NotesShim"),
        .target(name: "NoteModel"),
        .target(name: "NotesComponent", dependencies: ["AppCore", "Wire", "Launcher", "Agents", "NotesShim", "NoteModel"]),
        .executableTarget(name: "AppleNotesMCP", dependencies: ["AppCore", "NotesComponent"]),

        // Apple Reminders MCP.
        .target(name: "ReminderKitShim"),
        .target(name: "RemindersComponent", dependencies: ["AppCore", "Wire", "Launcher", "Agents", "ReminderKitShim"]),
        .executableTarget(name: "AppleRemindersMCP", dependencies: ["AppCore", "RemindersComponent"]),

        .testTarget(name: "AgentsTests", dependencies: ["Agents"]),
        .testTarget(name: "WireTests", dependencies: ["Wire"]),
        .testTarget(name: "NoteModelTests", dependencies: ["NoteModel"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "Agents", "Wire"]),
        .testTarget(name: "NotesComponentTests", dependencies: ["NotesComponent", "AppCore", "Wire"]),
        .testTarget(name: "RemindersComponentTests", dependencies: ["RemindersComponent", "AppCore", "Wire"]),
    ]
)
