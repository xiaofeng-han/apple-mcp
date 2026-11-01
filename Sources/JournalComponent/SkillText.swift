import AppCore

/// The skill's own text; the base adds the frontmatter and the command reference (see AppCore's Skill).
extension JournalComponent {
    nonisolated public static func skill(run: String) -> SkillText {
        SkillText(
            description: "Read and change the user's entries in Apple's Journal app on this Mac (entries, journals, attachments such as photos, places and State of Mind, and insights such as streaks, synced through iCloud to their devices) by running the apple-journal-mcp command. Use when the user asks about their journal or diary, or wants to write in it.",
            body: """
                # Apple Journal

                Run `\(run)` followed by a command, by that full path. It prints the answer as JSON, sometimes after a short lead such as `Created.`. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

                ```sh
                \(run) entries search "lake trip"
                \(run) entries read ID
                \(run) entries edit ID --version VERSION --append "- Swam before breakfast"
                \(run) entries create - --title "A good day" --journal Travel <<'EOF'
                We walked to the **lighthouse**.
                EOF
                ```

                ## Rules

                - Journal entries are private. Read only what the user's request needs, and share what they say only as the user asks.
                - Find entries with `entries list` (newest first; `--journal`, `--bookmarked`, `--after`/`--before` YYYY-MM-DD, `--attachment photo|video|audio|place|state_of_mind|workout|activity|music|podcast|book|contact|link|reflection|drawing|event|any|none`) or `entries search WORDS`, then `entries read ID`. Each comes with its `version`. `journals list` shows the journals and Journal's insights (days journaled, streaks).
                - Every change to an entry needs `--version` from `entries read`, `list` or `search`: `entries edit`, `entries delete`. An entry changed elsewhere since then is refused; read it again. Each change prints the new version.
                - Make all changes to one entry in a single `entries edit ID --version V` call: `--title`, `--body` (the whole text), `--replace '[{"old":"…","new":"…"}]'` (exact Markdown from `entries read`), `--append` (Markdown at the end), `--date 2026-10-21T09:30`, `--bookmarked` / `--no-bookmarked`, `--journal NAME` (`""` takes it out of its journal), `--attach FILE` (a photo, video or audio recording, by absolute path; repeat for more; `entries create` takes it too), `--detach ATTACHMENT_ID` (from `entries read`).
                - Entry text is Markdown, one paragraph per line: `**bold**`, `*italic*`, `<u>underline</u>`, `~~strike~~`, `*` and `-` lists, `1.` numbered, two spaces per indent level, `>` quote. Journal has no headings, tables or checklists: headings become bold text, checklist items bullets, and tables are refused.
                - Keep `![…](attachment:…)` placeholders where they are: they are photos, prompts and Genmoji placed in the text. `attachments read ID` prints an attachment's details and saves its photos, video frames and recordings, printing where.
                - `-` as the Markdown of `entries create`, or as `--body` or `--append`, reads it from stdin: use a quoted heredoc for text of several lines.
                - Deleting moves entries to Recently Deleted for 30 days (`entries list --deleted` lists them) and `entries restore ID` brings one back. Ask the user before `entries delete ID --version V --permanently` (only for an entry already there), and before `journals delete JOURNAL --delete-entries --expected-entries N`.
                - Journal uploads each change to iCloud; the answer says `"uploaded": true` once it has.
                - Every command also takes `--json '{...}'` (or `--json -` to read it from stdin) with the fields by their snake_case names; flags override it.
                - Agents that run commands in a sandbox (Codex does) cannot reach Journal from it: when the command says it ran inside a sandbox, run it again outside the sandbox, which the user may have to approve.
                - If the command says it lacks Full Disk Access, ask the user to run `\(run) setup` in a terminal.
                """)
    }
}
