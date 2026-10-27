import AppCore
import Wire

/// The tools on the command line: `apple-notes-mcp notes search "tax return"`. Commands print
/// exactly what the tool answers (text, often Markdown).
extension NotesComponent {
    nonisolated public static let cli = CLI(
        routes: routes,
        defaultVerbs: ["notes": "list", "folders": "list"],
        rewordings: [
            ("overview lists the folders", "folders list shows them"),
            ("with overview", "with folders list"),
            ("pass allow_shared: true", "add --allow-shared"),
            ("recursive: true and expected_notes", "--recursive and --expected-notes"),
            ("recursive needs expected_notes", "--recursive needs --expected-notes"),
        ],
        setupAbout: "Ask to control Notes, and show where to give Full Disk Access",
        clears: false, answer: "answer", nounsSummary: nil, saving: .everything, skillListsRequired: false)

    nonisolated static let routes: [Route] = [
        Route(noun: "notes", verb: "list", tool: "overview",
              about: "List notes, newest first, one line each (id | version | title | date | size | description)",
              detail: """
                  --folder includes its folders, and groups the notes by folder unless --sort is given. Dates are \
                  YYYY-MM-DD; the -after ones are inclusive, the -before ones exclusive. --undescribed lists the notes \
                  that need a description, with their opening text, for notes describe.
                  """,
              only: ["folder", "tags", "only", "attachments", "modified_after", "modified_before", "created_after", "created_before", "sort", "undescribed", "limit"],
              fallback: (["sort": "modified"], ["folder", "tags", "only", "attachments", "modified_after", "modified_before", "created_after", "created_before",
                                                "sort", "undescribed"])),
        Route(noun: "notes", verb: "search", tool: "search",
              about: "Full-text search of titles, text and the text Notes found in attachments, best matches first",
              positional: [("query", "QUERY")],
              only: ["match", "folder", "tags", "only", "attachments", "modified_after", "modified_before", "created_after", "created_before", "sort", "limit"]),
        Route(noun: "notes", verb: "read", tool: "read_note",
              about: "Print notes as Markdown, each with the version that notes edit takes",
              detail: """
                  By id, several (--id repeats, up to 20), or --title. A long note can be read one --section at a \
                  time, or as an --outline first.
                  """,
              positional: [("id", "ID")], only: ["ids", "title", "section", "outline"]),
        Route(noun: "notes", verb: "create", tool: "create_note",
              about: "Create a note from Markdown; its first line is the title",
              detail: "![name](/path/to/file) in the Markdown attaches a file, ![](https://…) adds a link card.",
              positional: [("markdown", "MARKDOWN")], only: ["folder"], required: ["markdown"],
              abouts: ["markdown": "The note as Markdown; - reads it from stdin"], stdin: ["markdown"]),
        Route(noun: "notes", verb: "copy", tool: "create_note",
              about: "Copy a note with everything in it, into its own folder or --folder",
              positional: [("copy_of", "ID")], only: ["folder"], required: ["copy_of"]),
        Route(noun: "notes", verb: "edit", tool: "edit_note",
              about: "Change a note in one go: --replace pairs, --insert Markdown, or --rewrite the whole note; --[no-]pinned",
              detail: """
                  --version is the one notes read, list or search gave; a note changed elsewhere since then is \
                  refused, so read it again. --replace takes exact Markdown from notes read, applied in order. \
                  --insert adds at the end, the start, or under a heading (--at). Only what changes is written; the \
                  rest keeps all its formatting.
                  """,
              positional: [("id", "ID")], only: ["version", "replace", "insert", "at", "rewrite", "check", "uncheck", "checklist", "pinned"],
              abouts: ["version": "From notes read, list or search", "replace": "A JSON list of {old, new, all}, applied in order",
                       "insert": "Markdown to add; - reads it from stdin", "rewrite": "The whole note as Markdown; - reads it from stdin"],
              stdin: ["insert", "rewrite"]),
        Route(noun: "notes", verb: "delete", tool: "delete_note",
              about: "Move a note to Recently Deleted (notes move brings it back; notes list --folder \"Recently Deleted\" lists them)",
              detail: "--version is the one notes read, list or search gave; a note changed elsewhere since then is refused.",
              positional: [("id", "ID")]),
        Route(noun: "notes", verb: "move", tool: "move_note",
              about: "Move a note to another folder, or back from Recently Deleted",
              detail: """
                  --version is the one notes read, list or search gave; a note changed elsewhere since then is refused. \
                  A move into or out of a shared folder needs --allow-shared, after asking the user. --folder \
                  "Recently Deleted" on notes list shows the deleted notes.
                  """,
              positional: [("id", "ID"), ("folder", "FOLDER")]),
        Route(noun: "notes", verb: "describe", tool: "describe_note",
              about: "Save one-line descriptions of notes, which notes list shows; many notes at once",
              abouts: ["descriptions": "A JSON list of 1 to 200 {\"id\", \"description\"}, each under 80 characters"]),

        Route(noun: "tags", verb: "rename", tool: "manage_tag", about: "Rename a tag in every note that has it",
              fixed: ["action": "rename"], positional: [("tag", "TAG"), ("name", "NAME")], only: [], required: ["name"],
              abouts: ["tag": "The tag, # optional", "name": "The new name"]),
        Route(noun: "tags", verb: "delete", tool: "manage_tag",
              about: "Take a tag out of every note that has it (ask the user first); the notes stay",
              detail: "--expected-notes is the number of notes with the tag, which folders list shows.",
              fixed: ["action": "delete"], positional: [("tag", "TAG")], only: ["expected_notes"], required: ["expected_notes"],
              abouts: ["tag": "The tag, # optional", "expected_notes": "The number of notes with the tag"]),

        Route(noun: "attachments", verb: "read", tool: "read_attachment",
              about: "Open an attachment from a ![…](attachment:ID) placeholder: print its text, save its images, audio and files",
              positional: [("id", "ID")],
              output: ("--output-dir", "Where to save its images, audio and files; default the temporary folder")),

        Route(noun: "folders", verb: "list", tool: "overview",
              about: "The folders, with how many notes each holds", only: ["depth"]),
        Route(noun: "folders", verb: "create", tool: "manage_folder", about: "Create a folder; a path such as Projects/Ideas makes it inside another",
              detail: "With --tag (repeat for more), a smart folder of the notes with any of the tags, or with --match all, all of them.",
              fixed: ["action": "create"], positional: [("folder", "PATH")], only: ["tags", "match"],
              abouts: ["folder": "The new folder's path, such as \"Projects/Ideas\""]),
        Route(noun: "folders", verb: "rename", tool: "manage_folder", about: "Rename a folder",
              detail: "A shared folder needs --allow-shared, after asking the user: the new name changes it for everyone.",
              fixed: ["action": "rename"], positional: [("folder", "FOLDER"), ("name", "NAME")], only: ["allow_shared"], required: ["name"],
              abouts: ["folder": "Path or id"]),
        Route(noun: "folders", verb: "move", tool: "manage_folder", about: "Move a folder into another, or to the top level with \"\"",
              detail: "A shared folder needs --allow-shared, after asking the user.",
              fixed: ["action": "move"], positional: [("folder", "FOLDER"), ("into", "INTO")], only: ["allow_shared"], required: ["into"],
              abouts: ["folder": "Path or id", "into": "The folder to put it in; \"\" for the top level"]),
        Route(noun: "folders", verb: "delete", tool: "manage_folder",
              about: "Delete an empty folder, or with --recursive --expected-notes N everything in it (ask the user first)",
              detail: "The notes go to Recently Deleted. --expected-notes is the number of notes you saw in it and its folders.",
              fixed: ["action": "delete"], positional: [("folder", "FOLDER")], only: ["recursive", "expected_notes"],
              abouts: ["folder": "Path or id", "recursive": "Also everything in it", "expected_notes": "With --recursive: the notes you saw in it and its folders"]),
        Route(noun: "folders", verb: "export", tool: "manage_folder",
              about: "Write a folder and its folders as Markdown with the original attachments, to a new folder or .zip",
              fixed: ["action": "export"], positional: [("folder", "FOLDER"), ("to", "TO")], only: [], required: ["to"],
              abouts: ["folder": "Path or id", "to": "A new folder or .zip path"]),
    ]
}
