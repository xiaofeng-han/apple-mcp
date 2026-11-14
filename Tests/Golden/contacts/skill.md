---
name: apple-contacts
description: Read and change the user's Apple Contacts on this Mac (people and companies with every field and their notes, groups, smart lists, linked cards, the My Card; synced through iCloud to their devices) by running the apple-contacts-mcp command. Use when the user asks about a contact, someone's phone, email, address or birthday, or their address book.
metadata:
  generated-by: apple-contacts-mcp
  command: "<EXECUTABLE>"
---

# Apple Contacts

Run `<EXECUTABLE>` followed by a command, by that full path. It prints the answer as JSON, sometimes after a short lead such as `Created.`. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

```sh
<EXECUTABLE> contacts search "jane acme"
<EXECUTABLE> contacts read ID
<EXECUTABLE> contacts create --first-name Jane --last-name Doe --phones '[{"label":"mobile","value":"+1 555 0100"}]'
<EXECUTABLE> contacts update ID --version VERSION --job-title "Designer" --note "Met at WWDC"
<EXECUTABLE> groups list
<EXECUTABLE> groups add "Family" --member ID
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
- If Contacts access is missing, ask the user to run `<EXECUTABLE> setup` in a terminal.

## Commands

### contacts

- `contacts list`: List contacts, sorted as Contacts sorts them, with their ids and versions. Filters combine: --group (nested groups included), --smart-list, --account, --type, --criteria (smart-list rules). --offset gives the next page.
  - `--group string` Only members of this group (name or id), including its nested groups
  - `--smart-list string` Only what this smart list holds (name or id)
  - `--account string` Only cards in this account (name or id)
  - `--type person|company` Only people or only companies
  - `--criteria json` {match: all|any, rules: [{field, op, value}]}; a rule may itself be {match, rules}. Fields: any (any text on the card; ops contains, not_contains); name, first_name, last_name, middle_name, nickname, organization, department, job_title, note, phone, email, url, instant_message, street, city, state, zip, country (ops contains, not_contains, is, is_not, is_set, is_not_set; phone/email/url/instant_message also starts_with, ends_with); address (contains, not_contains, is_set, is_not_set); birthday, anniversary, date (next_days, within_days, not_within_days with a number of days; is_set, is_not_set); modified (changed_within_days, not_changed_within_days with days; after with 2026-10-21); group (member_of, not_member_of a group or smart list, by name or id)
  - `--limit int` Default 50, at most 500
  - `--offset int` Skip this many, for the next page

- `contacts search [QUERY]`: Find contacts with all these words anywhere on the card (names, company, phones, emails, addresses, note, …). --phone and --email match a whole number or address; the list filters work here too.
  - `--account string` Only cards in this account (name or id)
  - `--criteria json` {match: all|any, rules: [{field, op, value}]}; a rule may itself be {match, rules}. Fields: any (any text on the card; ops contains, not_contains); name, first_name, last_name, middle_name, nickname, organization, department, job_title, note, phone, email, url, instant_message, street, city, state, zip, country (ops contains, not_contains, is, is_not, is_set, is_not_set; phone/email/url/instant_message also starts_with, ends_with); address (contains, not_contains, is_set, is_not_set); birthday, anniversary, date (next_days, within_days, not_within_days with a number of days; is_set, is_not_set); modified (changed_within_days, not_changed_within_days with days; after with 2026-10-21); group (member_of, not_member_of a group or smart list, by name or id)
  - `--email string` An email address
  - `--group string` Only members of this group (name or id), including its nested groups
  - `--limit int` Default 50, at most 500
  - `--offset int` Skip this many, for the next page
  - `--phone string` A phone number, in any format
  - `--smart-list string` Only what this smart list holds (name or id)
  - `--type person|company` Only people or only companies

- `contacts read [ID]`: Print contacts in full, with the note, groups, cards and the version update and delete take. By id (a contact's or one of its cards'), or several (--id repeats, up to 20).
  - `--id string…` Several, up to 20

- `contacts create`: Create a contact: --first-name, --last-name, --organization, --phones JSON, --note, --photo FILE, …. Lists are JSON: --phones '[{"label":"mobile","value":"+1 555 0100"}]'. --note - reads the note from stdin.
  - `--type person|company` A person, or a company (Contacts' Mark as a Company: shown by its organization)
  - `--prefix string` Name prefix (Dr., Ms., …)
  - `--first-name string` First (given) name
  - `--middle-name string` Middle name
  - `--last-name string` Last (family) name
  - `--maiden-name string` Maiden name (previous family name)
  - `--suffix string` Name suffix (Jr., III, …)
  - `--nickname string` Nickname
  - `--phonetic-first-name string` Phonetic first name (how it is said)
  - `--phonetic-middle-name string` Phonetic middle name
  - `--phonetic-last-name string` Phonetic last name
  - `--organization string` Company
  - `--phonetic-organization string` Phonetic company
  - `--department string` Department
  - `--job-title string` Job title
  - `--name-order default|given_first|family_first` Name order for this card (Card > Reorder Last Name Before First)
  - `--note string` The note: plain text, up to about 150,000 characters (iCloud's limit)
  - `--phones json` Phone numbers; replaces them all {label: mobile, iPhone, home, work, school, main, home fax, work fax, pager, Apple Watch, other, or any text; value: Phone number}
  - `--emails json` Email addresses; replaces them all {label: home, work, school, iCloud, other, or any text; value: Email address}
  - `--urls json` Web addresses; replaces them all {label: homepage, home, work, school, other, or any text; value: URL}
  - `--addresses json` Postal addresses; replaces them all {city: City; country: Country name; country_code: ISO country code (us, cn, de, …); it sets the address layout; label: home, work, school, other, or any text; postal_code: ZIP or postal code; state: State, province or region; street: Street; lines separated by \n; sub_administrative_area: County; sub_locality: District or neighborhood}
  - `--dates json` Dates other than the birthday; replaces them all {label: anniversary, other, or any text; value: 2015-06-01, or 06-01 for a date that comes every year}
  - `--related-names json` Related people; replaces them all {label: mother, father, parent, spouse, partner, child, son, daughter, brother, sister, friend, manager, assistant, mother in law, brother in law, … (any of Contacts' 200-odd relations, in words), or any text; value: Their name}
  - `--social-profiles json` Social profiles; replaces them all {label: home, work, school, other, or any text; service: Twitter, Facebook, LinkedIn, Flickr, Myspace, Sina Weibo, Tencent Weibo, Yelp, or any service; url: Profile URL; user_id: The service's user identifier; username: User name}
  - `--instant-messages json` Instant-message addresses; replaces them all {label: home, work, school, other, or any text; service: Skype, Jabber, QQ, WeChat, MSN, Yahoo, ICQ, AIM, Facebook, Gadu-Gadu, Google Talk, or any service; username: User name}
  - `--birthday string` 1990-05-17, or 05-17 when the year is not known
  - `--other-birthday json|string` A birthday in another calendar (Contacts' lunar birthday): {calendar: chinese, hebrew, islamic, … , year, month, day, leap_month}
  - `--photo string` Absolute path of an image file (JPEG, PNG, HEIC) to use as the photo
  - `--photo-crop int…` With photo: the part of it shown, [x, y, width, height] in the image's pixels, x and y from its top left; default the centered square
  - `--ringtone string` Call ringtone: a tone id (system:Opening, …), <default> or <none>
  - `--text-tone string` Text tone: a tone id (texttone:Note, …), <default> or <none>
  - `--emergency-bypass off|calls|texts|both` Let calls and/or texts from them sound even when muted or in a Focus
  - `--[no-]downtime-allowed` Screen Time: they can reach the user during Downtime
  - `--account string` Account name or id; default Contacts' default account
  - `--group string…` Groups to put it in (name or id), in the same account
  - `--[no-]wait` Wait until iCloud (or the account's server) has it, usually 10–15 seconds and up to 45 (90 with a photo); default true. false answers once it is saved on this Mac

- `contacts update ID --version string`: Change only the fields given; --no-FIELD clears one, a list replaces the whole list. --version is the one contacts read, list or search gave; a contact changed elsewhere since is refused, so read it again. For a contact linked across accounts, --card picks the card new values go to.
  - Every flag of `contacts create` except `--account`, `--group`; to clear a field: `--no-prefix`, `--no-first-name`, `--no-middle-name`, `--no-last-name`, `--no-maiden-name`, `--no-suffix`, `--no-nickname`, `--no-phonetic-first-name`, `--no-phonetic-middle-name`, `--no-phonetic-last-name`, `--no-organization`, `--no-phonetic-organization`, `--no-department`, `--no-job-title`, `--no-note`, `--no-phones`, `--no-emails`, `--no-urls`, `--no-addresses`, `--no-dates`, `--no-related-names`, `--no-social-profiles`, `--no-instant-messages`, `--no-birthday`, `--no-other-birthday`, `--no-photo`, `--no-ringtone`, `--no-text-tone`
  - `--version string` The version read_contact or find_contacts gave (required)
  - `--card string` For a linked contact: the card (id) new values and single fields go to

- `contacts delete ID --version string`: Delete a contact on every device (ask the user first); this app keeps a copy for 30 days. --version is the one contacts read, list or search gave. --card deletes one card of a linked contact.
  - `--version string` The version read_contact or find_contacts gave (required)
  - `--card string` Only this card of a linked contact

- `contacts deleted`: List the contacts this app deleted in the last 30 days.

- `contacts restore ID`: Bring back a contact this app deleted (contacts deleted lists them).

- `contacts photo ID`: Save a contact's photo (or --which full / poster) and print where.
  - `--which photo|full|poster` photo: as Contacts shows it (default); full: the whole image; poster: the poster's picture
  - `--output string` Where to save the image; default a file in the temporary folder

- `contacts duplicates`: Find cards that look like the same person (same name in an account, or --by email_or_phone).
  - `--account string` Only this account (name or id)
  - `--by name|email_or_phone` Default name

- `contacts merge --id string… --version string…`: Merge cards into the first (--id A --version VA --id B --version VB …); ask the user first.
  - `--id string…` The cards (or contacts) to merge; the first one is kept (required)
  - `--version string…` Their versions, from read_contact or find_contacts, in the same order (required)

- `contacts link --id string…`: Link cards of the same person into one contact (--id A --id B …).
  - `--id string…` link: the contacts or cards to link (two or more) (required)

- `contacts unlink ID`: Unlink a card (or, given a contact, all its cards).

- `contacts prefer-name CARD`: Make this card give its linked contact the name.

- `contacts prefer-photo CARD`: Make this card give its linked contact the photo.

- `contacts me ID`: Make a contact the My Card (confirm with the user first).

- `contacts changes`: What changed since --since TOKEN; without it, the token to pass next time.
  - `--[no-]include-own` Include the saves this app made through Contacts' framework
  - `--since string` The token a previous call gave

- `contacts import FILE`: Import a .vcf file into an account (--account) and group (--group); --duplicates skip|update|keep_both|replace.
  - `--account string` Account (name or id); default Contacts' default account
  - `--duplicates skip|update|keep_both|replace` What to do with a card whose name exists already; default skip
  - `--group string` Also add the imported contacts to this group (name or id)

- `contacts export FILE`: Write contacts to a new .vcf file: --id, --group, --query, --my-card, or all.
  - `--group string` A group's or smart list's members (name or id)
  - `--id string…` These contacts
  - `--[no-]my-card` The My Card
  - `--[no-]notes` Include notes (default true)
  - `--[no-]photos` Include photos (default true)
  - `--query string` Contacts matching these words, as find_contacts
  - `--version 3.0|2.1` Default 3.0

### groups

- `groups list`: The groups by account, nested, with their counts, and the smart lists with their rules.

- `groups members [GROUP]`: A group's or smart list's members (--nested adds its nested groups'), and its distribution list.
  - `--[no-]nested` With group: include the members of its nested groups

- `groups create NAME`: Create a group (--account, --parent, --member ID…).
  - `--account string` create: the account (name or id); default Contacts' default account
  - `--parent string` create: put it inside this group; nest/unnest: the outer group (name or id)
  - `--member string…` create, add_members, remove_members: contact or card ids

- `groups rename GROUP NEW_NAME`: Rename a group.

- `groups delete GROUP`: Delete a group; its contacts stay.

- `groups add GROUP --member string…`: Add contacts to a group (--member ID…).
  - `--member string…` create, add_members, remove_members: contact or card ids (required)

- `groups remove GROUP --member string…`: Take contacts out of a group (--member ID…).
  - `--member string…` create, add_members, remove_members: contact or card ids (required)

- `groups nest GROUP --parent string`: Put a group inside another (--parent GROUP).
  - `--parent string` create: put it inside this group; nest/unnest: the outer group (name or id) (required)

- `groups unnest GROUP --parent string`: Take a group out of another (--parent GROUP).
  - `--parent string` create: put it inside this group; nest/unnest: the outer group (name or id) (required)

- `groups distribution GROUP --member string`: Choose the email, phone or address a member is reached by in a group (--member ID --email …).
  - `--member string` distribution: the member (contact or card id) (required)
  - `--email string` distribution: the member's email address the group uses
  - `--phone string` distribution: the member's phone number the group uses
  - `--address string` distribution: the label of the member's postal address the group uses

### smart-lists

- `smart-lists create NAME --criteria json`: Create a smart list from --criteria JSON (see --help), with --highlight.
  - `--criteria json` {match: all|any, rules: [{field, op, value}]}; a rule may itself be {match, rules}. Fields: any (any text on the card; ops contains, not_contains); name, first_name, last_name, middle_name, nickname, organization, department, job_title, note, phone, email, url, instant_message, street, city, state, zip, country (ops contains, not_contains, is, is_not, is_set, is_not_set; phone/email/url/instant_message also starts_with, ends_with); address (contains, not_contains, is_set, is_not_set); birthday, anniversary, date (next_days, within_days, not_within_days with a number of days; is_set, is_not_set); modified (changed_within_days, not_changed_within_days with days; after with 2026-10-21); group (member_of, not_member_of a group or smart list, by name or id) (required)
  - `--[no-]highlight` Highlight it when one of its contacts changes (Contacts' option)

- `smart-lists update SMART_LIST`: Change a smart list's name (--new-name), rules (--criteria) or highlight.
  - Every flag of `smart-lists create`
  - `--new-name string` New name

- `smart-lists delete SMART_LIST`: Delete a smart list (its contacts stay).

### accounts

- `accounts list`: The accounts with their counts and the default one, the groups, smart lists and My Card.

- `accounts default ACCOUNT`: Make an account the one new contacts go to.

- `accounts sync [ACCOUNT]`: Ask Contacts to sync accounts now (one, or all).

### settings

- `settings show`: Contacts' settings.

- `settings set`: Change Contacts' settings: --sort-by, --address-format, --vcard-version, --[no-]vcard-notes, --[no-]vcard-photos, --[no-]private-my-card.
  - `--address-format string` Country whose address layout Contacts uses (ISO code: us, cn, de, …)
  - `--[no-]private-my-card` Leave out the My Card's private fields when it is shared
  - `--sort-by first_name|last_name` Sort contacts by
  - `--[no-]vcard-notes` Export notes in vCards
  - `--[no-]vcard-photos` Export photos in vCards
  - `--vcard-version 3.0|2.1` vCard format for export
