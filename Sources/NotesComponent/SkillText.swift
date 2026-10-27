import AppCore

/// The skill's own text; the base adds the frontmatter and the command reference (see AppCore's Skill).
extension NotesComponent {
    nonisolated public static func skill(run: String) -> SkillText {
        SkillText(
            description: "Read and change the user's Apple Notes on this Mac (notes, folders and attachments, synced through iCloud to their devices) by running the apple-notes-mcp command. Use when the user asks about their notes or Apple Notes.",
            body: """
                # Apple Notes

                Run `\(run)` followed by a command, by that full path. It prints the answer as text, often Markdown. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

                ```sh
                \(run) notes search "tax return"
                \(run) notes read ID
                \(run) notes edit ID --version VERSION --insert "- [ ] Call the bank" --at "To do"
                \(run) notes create - --folder Projects <<'EOF'
                # Trip plan
                - [ ] Book the train
                EOF
                ```

                ## Rules

                - Find notes with `notes list` (newest first; `--folder`, `--tag`, `--only pinned|shared|locked|quick-notes|math-notes|calls|checklists|unchecked|tagged|untagged|mentions`, `--attachment KIND`, dates, `--sort opened`) or `notes search QUERY` (it also searches text in images, handwriting and recording transcripts), then `notes read ID`. Each line and each note comes with its `version`. `folders list` shows the folders, smart folders and tags.
                - Every change needs `--version` from `notes read`, `list` or `search`: `notes edit`, `notes move`, `notes delete`. A note changed elsewhere since then is refused; read it again. Each change prints the new version.
                - Make all changes to one note in a single `notes edit ID --version V` call: `--replace '[{"old":"…","new":"…"}]'` takes exact Markdown from `notes read`, `--insert` adds Markdown (`--at` start, end or a heading's text), `--rewrite` replaces the whole note, `--check TEXT` / `--uncheck TEXT` tick checklist items, `--checklist check_all|uncheck_all|move_checked_down|delete_checked`, `--pinned` / `--no-pinned`.
                - Each paragraph is one Markdown line: `# title`, `## heading`, `### subheading`, `*` and `-` lists, `1.` numbered, `- [ ]` / `- [x]` checkboxes, `>` quote, two spaces per indent level, ``` monospaced, `**bold**`, `*italic*`, `~~strike~~`, `<u>underline</u>`, `<mark>highlight</mark>` (`<mark class="pink">` and orange, mint, blue), `[link](url)`, `| tables |`, `#tag`, `[text](note:ID)` a link to a note, `---` a divider. The first line of a new note is its title.
                - Keep `![…](attachment:…)` placeholders where they are. `![name](/path/to/file)` attaches a file and `![](https://…)` adds a link card. `attachments read ID` prints what can be read from one (with a recording's transcript) and saves its images, audio and files, printing where.
                - `-` as the Markdown of `notes create`, or as `--insert` or `--rewrite`, reads it from stdin: use a quoted heredoc for notes of several lines.
                - Moving a note into or out of a shared folder, or renaming a shared folder, changes who sees it: ask the user, then add `--allow-shared`.
                - Deleting moves notes to Recently Deleted for 30 days (`notes list --folder "Recently Deleted"` lists them), and `notes move ID FOLDER --version V` brings one back. Ask the user before deleting a folder with what is in it (`folders delete FOLDER --recursive --expected-notes N`) or a tag from every note (`tags delete TAG --expected-notes N`); `folders export` keeps a copy first.
                - To describe many notes: `notes list --undescribed`, then one `notes describe --descriptions '[{"id":"…","description":"…"}]'`.
                - Every command also takes `--json '{...}'` (or `--json -` to read it from stdin) with the fields by their snake_case names; flags override it.
                - Agents that run commands in a sandbox (Codex does) cannot reach Notes from it: when the command says it ran inside a sandbox, run it again outside the sandbox, which the user may have to approve.
                - If the command says it lacks Full Disk Access or may not control Notes, ask the user to run `\(run) setup` in a terminal.
                """)
    }
}
