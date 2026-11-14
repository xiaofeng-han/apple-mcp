import AppCore

/// The skill's own text; the base adds the frontmatter and the command reference (see AppCore's Skill).
enum ContactsSkill {
    static func text(run: String) -> SkillText {
        SkillText(
            description: "Read and change the user's Apple Contacts on this Mac (people and companies with every field and their notes, groups, smart lists, linked cards, the My Card; synced through iCloud to their devices) by running the apple-contacts-mcp command. Use when the user asks about a contact, someone's phone, email, address or birthday, or their address book.",
            body: """
                # Apple Contacts

                Run `\(run)` followed by a command, by that full path. It prints the answer as JSON, sometimes after a short lead such as `Created.`. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

                ```sh
                \(run) contacts search "jane acme"
                \(run) contacts read ID
                \(run) contacts create --first-name Jane --last-name Doe --phones '[{"label":"mobile","value":"+1 555 0100"}]'
                \(run) contacts update ID --version VERSION --job-title "Designer" --note "Met at WWDC"
                \(run) groups list
                \(run) groups add "Family" --member ID
                ```

                ## Rules

                - Read before you change: `contacts search`, `contacts list` or `contacts read ID` give each contact's `id` and `version`. `contacts update` and `contacts delete` need both and refuse a contact changed elsewhere since it was read; read it again.
                - `contacts search` works like Contacts' search field: every word must appear somewhere on the card, the note included. `--phone` and `--email` match a whole number or address.
                - A list field (`--phones`, `--emails`, `--urls`, `--addresses`, `--dates`, `--related-names`, `--social-profiles`, `--instant-messages`) is JSON in single quotes and replaces the whole list; `--no-FIELD` clears a field. Labels are plain words: home, work, mobile, iPhone, main, home fax, homepage, anniversary, mother, …, or any text.
                - Birthdays are `1990-05-17`, or `05-17` when the year is not known; `--other-birthday '{"calendar":"chinese","month":4,"day":23}'` sets a lunar birthday.
                - A contact can be several linked cards (one per account). `contacts read` lists them; changes go to the card that gives the contact its name, or `--card ID`. `contacts link`, `unlink`, `prefer-name` and `prefer-photo` manage links; `contacts merge` merges cards (ask the user first).
                - Contacts has no Recently Deleted: `contacts delete` removes a contact from every device, so ask the user first. This app keeps a copy for 30 days: `contacts deleted` lists them and `contacts restore ID` brings one back.
                - Groups hold cards of their own account and can be nested (`groups nest GROUP --parent OUTER`). Smart lists (`smart-lists create NAME --criteria JSON`) fill themselves from rules and stay on this Mac.
                - Every command also takes `--json '{...}'` (or `--json -` to read it from stdin) with the fields by their snake_case names; flags override it.
                - Agents that run commands in a sandbox (Codex does) cannot reach Contacts from it: when the command says it ran inside a sandbox, run it again outside the sandbox, which the user may have to approve.
                - Confirm with the user before deleting, merging or changing the My Card, and never invent details they did not give.
                - If Contacts access is missing, ask the user to run `\(run) setup` in a terminal.
                """)
    }
}
