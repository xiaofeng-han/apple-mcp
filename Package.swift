// swift-tools-version:6.2
// Apple Notes MCP, Apple Reminders MCP and Apple Journal MCP: MCP servers that let AI agents read
// and write Apple Notes, Apple Reminders and Journal natively, built from one package. Each app
// keeps its own name, command, permissions and executable (a main.swift of one line); the shared
// base is Wire (MCP over stdio, the command line's flags, the choice of tools), Launcher (holding
// the app's own privacy permissions), Agents (finding AI agents and setting them up) and AppCore
// (the modes, the command line, the settings window). Each app's own code is a component
// (NotesComponent, RemindersComponent, JournalComponent) that AppCore runs. See docs/MERGE-PLAN.md.
//
// Notes reads through Notes' own data model and edits in place through its private NotesShared
// framework (NotesShim, NoteModel). Reminders writes through the private ReminderKit framework
// (ReminderKitShim). Journal reads and writes through its private JournalShared framework, whose
// Swift interface is written by hand (Interfaces/Journal). All stay native and sync through iCloud.
import Foundation
import PackageDescription

/// Interfaces/Journal: the hand-written Swift interfaces of Journal's frameworks, and the stubs the
/// linker reads in place of the frameworks (see scripts/journal-stubs.sh). An absolute path, since
/// the compiler and linker do not run in the package's folder.
let journalInterfaces = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Interfaces/Journal").path

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

        // Apple Journal MCP. Journal has no Objective-C surface to speak of, so JournalComponent calls
        // Journal's own Swift frameworks (JournalShared, Coherence) through interfaces written by hand
        // (Interfaces/Journal), linked weakly so the app still starts where they differ. JournalModel
        // is everything that needs no Journal (what agents see, the text's Markdown form, insights,
        // attachments' details), so its tests build without those interfaces.
        .target(name: "JournalModel", dependencies: ["AppCore", "Agents", "Wire", "NoteModel"]),
        .target(name: "JournalComponent", dependencies: ["AppCore", "Wire", "Launcher", "Agents", "NoteModel", "JournalModel"],
                swiftSettings: [.unsafeFlags(["-I", journalInterfaces])],
                linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_library", "-Xlinker", journalInterfaces + "/JournalShared.tbd",
                                               "-Xlinker", "-weak_library", "-Xlinker", journalInterfaces + "/Coherence.tbd"])]),
        .executableTarget(name: "AppleJournalMCP", dependencies: ["AppCore", "JournalComponent"],
                          swiftSettings: [.unsafeFlags(["-I", journalInterfaces])]),

        .testTarget(name: "AgentsTests", dependencies: ["Agents"]),
        .testTarget(name: "WireTests", dependencies: ["Wire"]),
        .testTarget(name: "NoteModelTests", dependencies: ["NoteModel"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "Agents", "Wire"]),
        .testTarget(name: "NotesComponentTests", dependencies: ["NotesComponent", "AppCore", "Wire"]),
        .testTarget(name: "RemindersComponentTests", dependencies: ["RemindersComponent", "AppCore", "Wire"]),
        .testTarget(name: "JournalModelTests", dependencies: ["JournalModel", "AppCore", "Wire", "NoteModel"]),
    ]
)
