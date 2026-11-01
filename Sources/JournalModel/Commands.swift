import AppCore
import Wire

/// The tools on the command line: `apple-journal-mcp entries search "lake trip"`. Commands print
/// exactly what the tool answers (JSON, sometimes after a short lead such as "Created.").
package enum JournalCommands {
    package static let cli = CLI(
        routes: routes,
        defaultVerbs: ["entries": "list", "journals": "list"],
        rewordings: [
            ("find_entries with deleted: true", "entries list --deleted"),
            ("deleted: true", "--deleted"),
        ],
        setupAbout: "Check Full Disk Access, and show where to give it",
        clears: false, answer: "JSON answer", nounsSummary: nil, saving: .everything, skillListsRequired: false)

    static let routes: [Route] = [
        Route(noun: "entries", verb: "list", tool: "find_entries",
              about: "List entries, newest first, with their ids and versions",
              detail: """
                  Filters combine: --journal, --bookmarked, --after (inclusive) and --before (exclusive) dates as \
                  YYYY-MM-DD, --attachment KIND (repeat for more; any, none), --deleted for Recently Deleted. \
                  --offset gives the next page.
                  """,
              only: ["journal", "bookmarked", "after", "before", "attachments", "deleted", "sort", "limit", "offset"]),
        Route(noun: "entries", verb: "search", tool: "find_entries",
              about: "Find entries with all these words: in the text, title, prompt, and attachments' places, songs, transcripts",
              positional: [("query", "QUERY")]),
        Route(noun: "entries", verb: "read", tool: "read_entry",
              about: "Print entries in full, the text as Markdown, each with the version entries edit takes",
              detail: "By id, or several (--ids repeats, up to 20).",
              positional: [("id", "ID")]),
        Route(noun: "entries", verb: "create", tool: "create_entry",
              about: "Create an entry from Markdown, with --title, --date, --journal, --bookmarked, --attach FILE",
              positional: [("body", "MARKDOWN")],
              abouts: ["body": "The text as Markdown; - reads it from stdin", "attach": "A photo, video or audio recording to add"],
              stdin: ["body"]),
        Route(noun: "entries", verb: "edit", tool: "edit_entry",
              about: "Change an entry in one go: --title, --body, --replace pairs, --append, --date, --[no-]bookmarked, --journal, --attach, --detach",
              detail: """
                  --version is the one entries read, list or search gave; an entry changed elsewhere since then is \
                  refused, so read it again. --replace takes exact Markdown from entries read, applied in order. \
                  --journal "" takes it out of its journal. Only what changes is written; the rest keeps its formatting.
                  """,
              positional: [("id", "ID")],
              abouts: ["version": "From entries read, list or search", "replace": "A JSON list of {old, new, all}, applied in order",
                       "body": "The whole text as Markdown; - reads it from stdin", "append": "Markdown to add at the end; - reads it from stdin",
                       "attach": "A photo, video or audio recording to add",
                       "detach": "An attachment's id, from entries read, to take off"],
              stdin: ["body", "append"]),
        Route(noun: "entries", verb: "delete", tool: "delete_entry",
              about: "Move an entry to Recently Deleted; --permanently deletes one there for good (ask the user first)",
              detail: "--version is the one entries read, list or search gave; an entry changed elsewhere since then is refused.",
              positional: [("id", "ID")]),
        Route(noun: "entries", verb: "restore", tool: "restore_entry",
              about: "Bring an entry back from Recently Deleted (entries list --deleted lists them)", positional: [("id", "ID")]),
        Route(noun: "entries", verb: "duplicate", tool: "duplicate_entry",
              about: "Copy an entry with its text, date, journal and attachments", positional: [("id", "ID")]),
        Route(noun: "entries", verb: "export", tool: "export_entries",
              about: "Write entries as Markdown files with their photos, videos and recordings into a new folder",
              positional: [("to", "FOLDER")]),

        Route(noun: "journals", verb: "list", tool: "overview",
              about: "The journals with their entries, colors and icons, the counts, and Journal's insights (streaks, days journaled)"),
        Route(noun: "journals", verb: "create", tool: "manage_journal", about: "Create a journal, with --color and --icon",
              fixed: ["action": "create"], positional: [("journal", "NAME")], only: ["color", "icon"]),
        Route(noun: "journals", verb: "update", tool: "manage_journal", about: "Change a journal's name, color or icon",
              fixed: ["action": "update"], positional: [("journal", "JOURNAL")], only: ["new_name", "color", "icon"]),
        Route(noun: "journals", verb: "delete", tool: "manage_journal",
              about: "Delete a journal; its entries stay in All Entries, move (--move-entries-to), or go too (--delete-entries --expected-entries N; ask the user first)",
              fixed: ["action": "delete"], positional: [("journal", "JOURNAL")], only: ["move_entries_to", "delete_entries", "expected_entries"],
              abouts: ["move_entries_to": "The journal to move its entries to", "delete_entries": "Move its entries to Recently Deleted too",
                       "expected_entries": "With --delete-entries: how many entries it holds"]),

        Route(noun: "attachments", verb: "read", tool: "read_attachment",
              about: "Open an entry's attachment (ids from entries read): print its details, save its photos, video frames and recordings",
              positional: [("id", "ID")],
              output: ("--output-dir", "Where to save its images, audio and files; default the temporary folder")),
    ]
}
