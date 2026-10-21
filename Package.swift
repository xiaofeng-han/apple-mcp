// swift-tools-version:6.2
// Apple Notes MCP: an MCP server for Apple Notes. Notes are read through Notes' own data model
// and edited in place through its private NotesShared framework, so titles, lists, checklists,
// tables and formatting stay native and sync through iCloud.
import PackageDescription

let package = Package(
    name: "AppleNotesMCP",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "Wire"),
        .target(name: "Launcher"),
        .target(name: "NotesShim"),
        .target(name: "NoteModel"),
        .target(name: "Agents", dependencies: ["Launcher"]),
        .executableTarget(name: "AppleNotesMCP", dependencies: ["Wire", "Launcher", "NotesShim", "NoteModel", "Agents"]),
        .testTarget(name: "AgentsTests", dependencies: ["Agents"]),
        .testTarget(name: "WireTests", dependencies: ["Wire"]),
        .testTarget(name: "NoteModelTests", dependencies: ["NoteModel"]),
    ]
)
