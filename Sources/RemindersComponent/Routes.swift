import AppCore
import Wire

/// The tools on the command line: `apple-reminders-mcp reminders find --list Groceries`. Commands
/// print exactly what the tool answers (JSON, sometimes after a short lead such as "Created.").
extension RemindersComponent {
    nonisolated public static let cli = CLI(
        routes: routes,
        defaultVerbs: ["lists": "list", "tags": "list"],
        rewordings: [
            ("manage_list (group: null)", "lists update --no-group"),
            ("confirm_delete_reminders: true", "--confirm-delete-reminders"),
        ],
        setupAbout: "Ask for access to Reminders (alias: authorize)",
        clears: true, answer: "JSON answer", nounsSummary: "reminders, lists, …", saving: .images, skillListsRequired: true)

    nonisolated static let routes: [Route] = [
        Route(noun: "reminders", verb: "find", tool: "find_reminders",
              about: "Find reminders across lists, open ones first by due date; QUERY matches the title or notes",
              detail: """
                  Filters combine. --due-before is exclusive: --due-before with tomorrow's date gives everything due \
                  today or overdue. Each reminder appears once, with smart_lists naming the smart lists that show it. \
                  The answer also gives now and time_zone.
                  """,
              positional: [("query", "QUERY")]),
        Route(noun: "reminders", verb: "get", tool: "get_reminder",
              about: "Read one reminder in full: alarms, early alerts, images, subtasks, and its current version",
              positional: [("id", "ID")]),
        Route(noun: "reminders", verb: "create", tool: "create_reminder",
              about: "Create a reminder; without --list it goes to the default list (or the parent's list)",
              positional: [("title", "TITLE")], clears: false),
        Route(noun: "reminders", verb: "update", tool: "update_reminder",
              about: "Change only the fields given; --no-FIELD clears one",
              detail: """
                  Pass the --version that find or get gave; a reminder changed elsewhere since then is refused, so \
                  read it again. --completed checks it off: a repeating reminder leaves a completed copy and moves \
                  to its next date (unless that is turned off in the app's settings). --list moves it to another list.
                  """,
              positional: [("id", "ID")]),
        Route(noun: "reminders", verb: "delete", tool: "delete_reminder",
              about: "Move a reminder and its subtasks to Recently Deleted", positional: [("id", "ID")]),
        Route(noun: "reminders", verb: "deleted", tool: "list_deleted",
              about: "List reminders in Recently Deleted that restore can bring back, newest first",
              detail: "With Full Disk Access for the app this is everything in Recently Deleted; without it, what this app deleted."),
        Route(noun: "reminders", verb: "restore", tool: "restore_reminder",
              about: "Bring a reminder back from Recently Deleted, with the subtasks deleted along with it",
              detail: "Without --list it returns to the list it was deleted from, or the default list.",
              positional: [("id", "ID")]),
        Route(noun: "reminders", verb: "image", tool: "read_image",
              about: "Save an image on a reminder (ids from get) and print where; needs Full Disk Access",
              positional: [("reminder_id", "REMINDER_ID"), ("image_id", "IMAGE_ID")],
              output: ("--output", "Where to save the image; default a file in the temporary folder")),

        Route(noun: "lists", verb: "list", tool: "list_lists",
              about: "The lists (with counts, sections and the people on shared ones), groups, smart lists and templates"),
        Route(noun: "lists", verb: "create", tool: "manage_list", about: "Create a list",
              fixed: ["action": "create"], positional: [("list", "NAME")],
              only: ["color", "icon", "group", "pinned", "type", "sort", "position"], clears: false),
        Route(noun: "lists", verb: "update", tool: "manage_list",
              about: "Change a list's name, color, icon, group, pin, type, sort order or place in the sidebar",
              detail: "A groceries list sorts its items into aisles.",
              fixed: ["action": "update"], positional: [("list", "LIST")],
              only: ["new_name", "color", "icon", "group", "pinned", "type", "sort", "position"]),
        Route(noun: "lists", verb: "clear-completed", tool: "manage_list", about: "Move a list's completed reminders to Recently Deleted",
              fixed: ["action": "clear_completed"], positional: [("list", "LIST")], only: []),
        Route(noun: "lists", verb: "delete", tool: "manage_list",
              about: "Delete a list; one with reminders needs --confirm-delete-reminders (ask the user first)",
              detail: "Its reminders go to Recently Deleted.",
              fixed: ["action": "delete"], positional: [("list", "LIST")], only: ["confirm_delete_reminders"]),

        Route(noun: "groups", verb: "create", tool: "manage_group",
              about: "Create a group, which holds lists in the sidebar (put lists in it with lists update --group)",
              fixed: ["action": "create"], positional: [("group", "NAME")], only: []),
        Route(noun: "groups", verb: "rename", tool: "manage_group", about: "Rename a group",
              fixed: ["action": "rename"], positional: [("group", "GROUP"), ("new_name", "NEW_NAME")], only: [], required: ["new_name"]),
        Route(noun: "groups", verb: "delete", tool: "manage_group", about: "Delete an empty group",
              fixed: ["action": "delete"], positional: [("group", "GROUP")], only: []),

        Route(noun: "sections", verb: "create", tool: "manage_section",
              about: "Create a section in a list (put reminders in it with --section)",
              fixed: ["action": "create"], positional: [("list", "LIST"), ("section", "NAME")], only: []),
        Route(noun: "sections", verb: "rename", tool: "manage_section", about: "Rename a section",
              fixed: ["action": "rename"], positional: [("list", "LIST"), ("section", "SECTION"), ("new_name", "NEW_NAME")], only: [],
              required: ["new_name"]),
        Route(noun: "sections", verb: "move", tool: "manage_section", about: "Move a section next to another one",
              fixed: ["action": "move"], positional: [("list", "LIST"), ("section", "SECTION")], only: ["position"], required: ["position"]),
        Route(noun: "sections", verb: "delete", tool: "manage_section", about: "Delete a section; its reminders stay in the list",
              fixed: ["action": "delete"], positional: [("list", "LIST"), ("section", "SECTION")], only: []),

        Route(noun: "smart-lists", verb: "create", tool: "manage_smart_list",
              about: "Create a smart list, which shows the reminders matching its filters",
              fixed: ["action": "create"], positional: [("smart_list", "NAME")], only: ["filters", "match", "color", "icon"],
              required: ["filters"], clears: false),
        Route(noun: "smart-lists", verb: "update", tool: "manage_smart_list",
              about: "Change a smart list's name, color, icon, match or filters (--filters replaces them all)",
              fixed: ["action": "update"], positional: [("smart_list", "SMART_LIST")], only: ["new_name", "filters", "match", "color", "icon"]),
        Route(noun: "smart-lists", verb: "delete", tool: "manage_smart_list", about: "Delete a smart list; no reminders are deleted",
              fixed: ["action": "delete"], positional: [("smart_list", "SMART_LIST")], only: []),

        Route(noun: "tags", verb: "list", tool: "list_tags", about: "Every tag in use, with how many open and how many reminders in all have it"),
        Route(noun: "tags", verb: "rename", tool: "manage_tag",
              about: "Rename a tag on every reminder that has it, merging into a tag of that name if there is one",
              fixed: ["action": "rename"], positional: [("tag", "TAG"), ("new_name", "NEW_NAME")], only: [], required: ["new_name"]),
        Route(noun: "tags", verb: "delete", tool: "manage_tag", about: "Remove a tag from every reminder",
              fixed: ["action": "delete"], positional: [("tag", "TAG")], only: []),

        Route(noun: "templates", verb: "create", tool: "manage_template",
              about: "Save a list as a template (Reminders copies its reminders in the background)",
              fixed: ["action": "create"], positional: [("template", "NAME")], only: ["list", "include_completed"], required: ["list"],
              abouts: ["list": "The list to save (name or id)", "include_completed": "Keep completed reminders too; default false"]),
        Route(noun: "templates", verb: "use", tool: "manage_template", about: "Make a new list from a template",
              fixed: ["action": "use"], positional: [("template", "TEMPLATE")], only: ["list"],
              abouts: ["list": "The new list's name; default the template's"]),
        Route(noun: "templates", verb: "delete", tool: "manage_template", about: "Delete a template",
              fixed: ["action": "delete"], positional: [("template", "TEMPLATE")], only: []),
    ]
}
