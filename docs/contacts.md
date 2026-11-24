# Apple Contacts MCP

**English** | [简体中文](contacts.zh-CN.md)

Part of [apple-mcp](../README.md), the repository of Apple Contacts MCP, [Apple Notes MCP](notes.md), [Apple Reminders MCP](reminders.md) and [Apple Journal MCP](journal.md).

An MCP server that lets AI agents (Claude Code, Codex, Grok Build, OpenCode, Gemini CLI, pi, …) read and write Apple's Contacts on the Mac. Every tool is also a command-line command, so an agent can use a skill instead of the server. Its settings window finds the agents on your Mac and sets each one up either way with one click.

It works through Contacts' own frameworks, Contacts.framework and the older AddressBook framework that Contacts.app still uses, and through Contacts' AppleScript for the one thing macOS keeps from other apps: the notes. What an agent writes is ordinary Contacts data, which Contacts syncs through iCloud (or Google, Exchange, CardDAV) to every device:
- people and companies with every field Contacts has: the names (with phonetic, maiden name and name order), company, department, job title, the note, phones, emails, web addresses, postal addresses, birthday and a birthday in another calendar, other dates, related people, social profiles, instant-message addresses, the photo and its crop, ringtone and text tone, Emergency Bypass, and whether they can reach the user during Screen Time's Downtime;
- linked cards (one person with a card in several accounts): linking, unlinking, which card gives the name and the photo; merging duplicates;
- groups, nested groups and their distribution lists; smart lists with their rules;
- the My Card, the accounts (which one new contacts go to, syncing now), Contacts' settings, the change history, and vCard import and export;
- a copy of every contact it deletes, kept 30 days, since Contacts has no Recently Deleted.

It needs two permissions: Contacts, and Automation → Contacts (to read and write the notes).

Requires macOS 26 or later on Apple silicon; tested on macOS 27.2 with Contacts 14.0. All code is written for this project, with no third-party dependencies.

## What it covers

| Contacts | Here |
|---|---|
| Cards: every field, notes and photos included; people and companies | ✅ `create_contact`, `update_contact`, `read_contact` |
| Search (every word anywhere on the card, as Contacts' search field), by phone, email, group, smart list, account, kind; smart-list rules as a search | ✅ `find_contacts` |
| Delete; bring back (Contacts itself cannot) | ✅ `delete_contact`, `restore_contact` (30 days) |
| Linked cards: link, unlink, the card that gives the name or the photo | ✅ `link_contacts` |
| Look for Duplicates, Merge Selected Cards | ✅ `find_duplicates`, `merge_contacts` |
| Groups: create, rename, delete, members, nested groups, distribution lists | ✅ `list_groups`, `manage_group` |
| Smart lists: create, change the rules or highlight, delete | ✅ `manage_smart_list`; read in `list_groups` |
| Make This My Card | ✅ `set_my_card` |
| Accounts: counts, default account, Refresh Accounts | ✅ `overview`, `manage_accounts` |
| Import and export vCards (with notes and photos), Share My Card | ✅ `import_contacts`, `export_contacts` |
| Settings: sort order, address format, vCard options, private My Card | ✅ `settings` |
| What changed on any device since last time | ✅ `contact_changes` |
| Photo, full image and poster picture | ✅ `read_photo` (reading); the photo and its crop are written by `create_contact` and `update_contact` |
| Pronouns, Favorites, blocking, Emergency Contacts, Contact Posters, Name and Photo Sharing | ❌ see [Not possible](#not-possible) |
| Family members' (child) accounts | ❌ |
| Adding or removing accounts, turning Contacts sync on or off | ❌ System Settings → Internet Accounts |
| Printing (lists, envelopes, labels), CSV and LDIF import | ❌ |

## Tools

| Tool | What it does |
|---|---|
| `overview` | The accounts (iCloud, Google, On My Mac, …) with how many cards each holds and which one new contacts go to; how many contacts there are (cards linked across accounts count once); the groups and smart lists; the My Card |
| `find_contacts` | Contacts sorted as Contacts sorts them, each with its id and version: every word of `query` anywhere on the card (case and accents ignored), `phone` or `email` (a whole number or address, in any format), `group` (nested groups included), `smart_list`, `account`, `type`, or `criteria` (smart-list rules); pages with `limit` and `offset` |
| `read_contact` | Up to 20 contacts in full: every field, the note, the groups, whether there is a photo or poster, the tones, and the cards (which account, which gives the name and photo, each one's note), with the version |
| `read_photo` | The photo as Contacts shows it, the full image it is cropped from, or the poster's picture |
| `list_groups` | The groups by account, nested as in Contacts' sidebar, with their counts, and the smart lists with their rules; with `group`, its members (`nested` adds the nested groups') and its distribution list |
| `find_duplicates` | Cards that look like the same person: the same name in the same account, or (`by: email_or_phone`) a shared email address or phone number |
| `contact_changes` | The contacts and groups added, changed, linked or deleted on any device since a token from Contacts' change history; without `since`, the token to pass next time. Leaves out the saves this app made through Contacts.framework unless `include_own`; notes, group members, links and smart lists it changes through Contacts itself or AddressBook show like any other change |
| `create_contact` | A person or a company with any of the fields, in an account (default: Contacts' default account) and in groups |
| `update_contact` | Changes only the fields given; `null` clears one (on every linked card), a list replaces the whole list. A linked contact keeps each value on the card it is on, and a value two cards share stays on both; new values and changed fields go to the card that gives the name, or to `card`. A value written differently (case, spacing, punctuation) takes the new form |
| `delete_contact` | Deletes a contact (all its cards, or only `card`) from every device, keeping a copy for 30 days |
| `restore_contact` | Lists the copies kept, or brings one back with its id, fields, note, photo and groups, in its account |
| `manage_group` | Creates a group (in an account, inside another, with members), renames or deletes one (its contacts stay), adds or removes members, nests or unnests it, and chooses the email, phone or address a member is reached by in it (`distribution`) |
| `manage_smart_list` | Creates, changes (name, rules, highlight) or deletes a smart list |
| `link_contacts` | Links cards into one contact, unlinks a card or all of a contact's cards, or makes a card give the contact its name (`prefer_name`) or photo (`prefer_photo`) |
| `merge_contacts` | Merges cards into the first, as Merge Selected Cards does: every value kept, empty fields filled, notes joined, the photo kept, the groups added, the other cards deleted (and kept 30 days). Cards in other accounts are linked instead |
| `set_my_card` | Makes a contact the My Card, which Safari AutoFill, Messages and other apps use |
| `manage_accounts` | Sets the account new contacts go to, or asks Contacts to sync accounts now |
| `import_contacts` | Imports a `.vcf` file (with notes and photos) into an account and a group; a card with the same name as one there is skipped and listed (default), merged into it (`update`), added anyway (`keep_both`) or put in its place (`replace`: the new card is added in the old one's groups, the old one is deleted and kept 30 days, then the new one is linked to the old one's other cards and made the My Card if the old one was; a failure in those last steps comes back as a warning). If it stops part way, the error says what was imported before |
| `export_contacts` | Writes a new `.vcf` file: chosen contacts, a group's or smart list's, those matching a query, the My Card, or all; vCard 3.0 or 2.1, with notes and photos unless turned off |
| `settings` | Contacts' settings: sort order, name display and short names, address format, vCard export options, private My Card, Siri Suggestions; changes the sort order, address format, vCard options and private My Card |

Every change to a contact passes back the `version` that `read_contact` or `find_contacts` gave, and a contact changed since (in Contacts, on another device) is refused, so an agent never overwrites what it has not read. The version covers every field shown, the note included, but not the groups.

`create_contact` and `update_contact` answer once Contacts has uploaded the change to iCloud (or the account's server), with `"uploaded": true`, usually within 10 to 15 seconds and up to 45 (90 with a photo); `wait: false` answers as soon as it is saved on this Mac. The other writes answer once the change is saved on this Mac, and Contacts uploads it in the background. iCloud sometimes hands a card back slightly changed right after an upload (it stores the photo apart, and writes some service names its own way, such as Skype as `SkypeInstant`), so read a contact again before the next change.

### Contact fields

| Field | Form |
|---|---|
| `type` | `person` or `company` (Mark as a Company: the card shows its organization) |
| names | `prefix`, `first_name`, `middle_name`, `last_name`, `maiden_name`, `suffix`, `nickname`, `phonetic_first_name`, `phonetic_middle_name`, `phonetic_last_name`; `name_order`: `default`, `given_first` or `family_first` |
| work | `organization`, `phonetic_organization`, `department`, `job_title` |
| `note` | plain text, up to about 150,000 characters (iCloud's limit) |
| `phones`, `emails`, `urls` | lists of `{label, value}` |
| `addresses` | a list of `{label, street, sub_locality, city, sub_administrative_area, state, postal_code, country, country_code}`; the street's lines separated by `\n`; `country_code` sets the address layout |
| `birthday` | `1990-05-17`, or `05-17` when the year is not known |
| `other_birthday` | a birthday in another calendar (Contacts' lunar birthday): `{calendar, year, month, day, leap_month}`, with `chinese`, `hebrew`, `islamic` and the other calendars Contacts offers |
| `dates` | a list of `{label, value}`, `2015-06-01` or `06-01` |
| `related_names` | a list of `{label, value}`: the relation and their name |
| `social_profiles` | a list of `{label, service, username, user_id, url}` |
| `instant_messages` | a list of `{label, service, username}` |
| `photo` | the absolute path of a JPEG, PNG or HEIC file (up to 20 MB); `null` removes the photo. `photo_crop`, with `photo`: `[x, y, width, height]` in the image's pixels from its top left (on the command line `--photo-crop` four times), by default the centered square |
| `ringtone`, `text_tone` | a tone id (`system:Opening`, `texttone:Note`, …), `<default>` or `<none>` |
| `emergency_bypass` | `off`, `calls`, `texts` or `both`: calls or texts from them sound even when muted or in a Focus |
| `downtime_allowed` | Screen Time: they can reach the user during Downtime (see [How it works](#how-it-works)) |
| `account`, `groups` | on create: the account (name or id) and the groups (in that account) |

Labels are plain words: phones `mobile`, `iPhone`, `home`, `work`, `school`, `main`, `home fax`, `work fax`, `pager`, `Apple Watch`, `other`; emails `home`, `work`, `school`, `iCloud`; web addresses `homepage`; dates `anniversary`; related names any of Contacts' 200-odd relations (`mother`, `spouse`, `brother in law`, `grandfather fathers father`, …). Any other text is a custom label. Reading gives them back the same way.

### Notes

macOS gives a contact's note only to apps Apple has entitled (Contacts, Phone, Messages), so Contacts.framework hides it from this app and refuses to save a card that has one. The app reads and writes notes through Contacts' AppleScript, which asks once for Automation → Contacts; Contacts is started hidden when it is not running. To save any other change to a card with a note, the note is set aside: kept in `~/Library/Application Support/AppleContactsMCP/notes-aside.json`, taken off through AppleScript, the card saved, the note put back (or the new one written). Contacts uploads the result as one change. One process at a time sets notes aside (a lock next to the file), so two agents, or an agent and the command line, never undo each other's. If the app stops in between, or Contacts does not take the note back at once, the next call puts it back from that file; while Contacts is still starting, the app waits for it rather than take a card for missing.

### Linked cards

A contact can be several cards linked together, usually one per account; Contacts shows them as one. `read_contact` lists the cards with the account each is in, which one gives the name and the photo, and each card's note. An `id` can be the contact's or one of its cards'. `update_contact` changes a value on the card it is on and adds new values to the card that gives the name (or `card`); deleting a linked contact deletes every card unless `card` names one. Links are made through AddressBook, since Contacts.framework's linking fails in a long-running process once the card has changed in another.

### Groups and smart lists

A group belongs to one account and holds cards of that account, so `groups` on create and `members` take contacts that have a card there. Members are added and removed through Contacts' AppleScript (Contacts.framework accepts some removals without doing them) and checked afterwards. Nested groups and distribution lists (which email, phone or address a group's message goes to, per member) are Contacts' own; distribution choices stay on this Mac.

A smart list holds every contact that matches its rules, as Contacts' File > New Smart List:

```json
{"match": "all", "rules": [
  {"field": "organization", "op": "contains", "value": "Acme"},
  {"field": "birthday", "op": "next_days", "value": 30},
  {"match": "any", "rules": [{"field": "group", "op": "member_of", "value": "Family"},
                             {"field": "email", "op": "ends_with", "value": "@acme.com"}]}]}
```

Fields: `any` (any text on the card; `contains`, `not_contains`); `name`, `first_name`, `last_name`, `middle_name`, `nickname`, `organization`, `department`, `job_title`, `note`, `phone`, `email`, `url`, `instant_message`, `street`, `city`, `state`, `zip`, `country` (with `contains`, `not_contains`, `is`, `is_not`, `is_set`, `is_not_set`; phones, emails, URLs and instant messages also `starts_with` and `ends_with`); `address` (`contains`, `not_contains`, `is_set`, `is_not_set`); `birthday`, `anniversary`, `date` (`next_days`, `within_days`, `not_within_days` with a number of days; `is_set`, `is_not_set`); `modified` (`changed_within_days`, `not_changed_within_days`; `after` a date); `group` (`member_of`, `not_member_of` a group or smart list). `find_contacts` takes the same `criteria`, to see what a smart list would hold before making it. Contacts keeps smart lists on this Mac (On My Mac); they do not sync.

### Deleting and bringing back

Contacts deletes a card on every device at once and has no Recently Deleted. Before `delete_contact` or `merge_contacts` deletes a card, the app keeps a copy (every field, the note, the photo, the groups, the account) in `~/Library/Application Support/AppleContactsMCP/Deleted/`, for 30 days. `restore_contact` with no id lists them; with an id it puts the card back with the same id, so links to it (in Messages, Calendar, a related name) still work, then its groups and its note. If that stops part way (Automation not allowed yet, say), calling it again finishes the rest. A copy is removed again when the delete itself fails.

## Command line

Every tool is a command: `apple-contacts-mcp help` prints the tree, and any command takes `--help`.

```bash
apple-contacts-mcp accounts list                                       # accounts, counts, groups, My Card
apple-contacts-mcp contacts search "jane acme"                          # every word, anywhere on the card
apple-contacts-mcp contacts search --phone "+1 555 0100"
apple-contacts-mcp contacts list --group Family --type person
apple-contacts-mcp contacts read ID
apple-contacts-mcp contacts create --first-name Jane --last-name Doe --organization Acme \
    --phones '[{"label":"mobile","value":"+1 555 0100"}]' --birthday 05-17 --group Family
apple-contacts-mcp contacts update ID --version VERSION --job-title Designer --note "Met at WWDC"
apple-contacts-mcp contacts update ID --version VERSION --photo ~/Pictures/jane.heic
apple-contacts-mcp contacts update ID --version VERSION --no-nickname        # clears a field
apple-contacts-mcp contacts delete ID --version VERSION                      # a copy is kept 30 days
apple-contacts-mcp contacts deleted
apple-contacts-mcp contacts restore ID
apple-contacts-mcp contacts duplicates
apple-contacts-mcp contacts merge --id A --version VA --id B --version VB
apple-contacts-mcp contacts link --id CARD1 --id CARD2
apple-contacts-mcp contacts photo ID --which full --output ~/Desktop/jane.jpg
apple-contacts-mcp contacts changes --since TOKEN
apple-contacts-mcp contacts export ~/Desktop/family.vcf --group Family
apple-contacts-mcp contacts import ~/Downloads/cards.vcf --group Imported --duplicates update
apple-contacts-mcp groups create "Book club" --member ID --member ID
apple-contacts-mcp groups nest "Book club" --parent Friends
apple-contacts-mcp groups distribution "Book club" --member ID --email jane@work.example
apple-contacts-mcp smart-lists create "Birthdays soon" --criteria '{"rules":[{"field":"birthday","op":"next_days","value":14}]}'
apple-contacts-mcp settings set --sort-by first_name
```

Commands print the tool's JSON answer, sometimes after a short lead such as `Created.`. Exit status 1 means the request failed (not found, changed since it was read, not allowed), with the reason on stderr; 2 means a wrong command or flag. Every command also takes `--json '{...}'` (or `--json -` for stdin) with the fields by their snake_case names. `--note -` reads the note from stdin.

## Install

Releases are built for Apple silicon. The default way to install and set up is with Homebrew:

```bash
brew install --cask xiaofeng-han/tap/apple-contacts-mcp
apple-contacts-mcp setup                  # asks for Contacts and for Automation → Contacts
apple-contacts-mcp agents set-up --all    # register the server with the agents on this Mac
```

To give the agents the skill instead of the server, add `--skill` to the last command. Instead of the last two commands, you can open Apple Contacts MCP from Applications: set up your agents in its **AI Assistants** tab, and give both permissions under **General**.

Without Homebrew, download `AppleContactsMCP-<version>.pkg` from [Releases](https://github.com/xiaofeng-han/apple-mcp/releases) and open it, or install it from the terminal:

```bash
gh release download contacts-v0.1.0 -R xiaofeng-han/apple-mcp -p '*.pkg'
installer -pkg AppleContactsMCP-0.1.0.pkg -target CurrentUserHomeDirectory
```

Installing for yourself puts the app in `~/Applications` and needs no administrator password. The app and package have no Developer ID signature; the cask takes off the quarantine, and a package downloaded in a browser has to be allowed under System Settings → Privacy & Security.

### After installing

`setup` (or **General** in the window) asks for both permissions; macOS shows its own prompts. If one was declined, turn it on in System Settings → Privacy & Security → Contacts, and → Automation → Apple Contacts MCP → Contacts. To check:

```bash
apple-contacts-mcp --self-check
```

It prints both permissions, the accounts with their counts, the groups and smart lists, and how many deleted contacts it keeps.

The window's **AI Assistants** tab, **Set Up As** (server or skill) and the **Tools** tab work as in the other apps; see [Setting up your agents](reminders.md#setting-up-your-agents), [Server or skill](reminders.md#server-or-skill) and [Choosing the tools](reminders.md#choosing-the-tools), with `apple-contacts-mcp`, the server name `apple-contacts`, the skill `apple-contacts/SKILL.md` and `~/Library/Application Support/AppleContactsMCP/tools.json` in their place. By hand, the command is `/opt/homebrew/bin/apple-contacts-mcp --stdio` (or the app's executable, `AppleContactsMCP.app/Contents/MacOS/AppleContactsMCP`); for example `claude mcp add -s user apple-contacts -- /opt/homebrew/bin/apple-contacts-mcp --stdio`.

Agents that run commands in a sandbox (Codex does) cannot reach Contacts from it; the skill tells them to run the command outside the sandbox, which you may have to approve.

### Build from source

```bash
./scripts/build-app.sh contacts
ditto dist/AppleContactsMCP.app ~/Applications/AppleContactsMCP.app
```

`./scripts/build-pkg.sh contacts` builds the release package, and `scripts/release.sh contacts <version>` releases it, as described for [Apple Reminders MCP](reminders.md#build-from-source), with the note from [`CHANGELOG-contacts.md`](../CHANGELOG-contacts.md) and tags `contacts-v<version>`. The icon is `Resources/Contacts/AppIcon.icon`: `swift scripts/compose-icon.swift Resources/Reminders/AppIcon.icon/Assets/artwork.png Resources/Contacts/AppIcon.icon/Assets/artwork.png contacts`, then `./scripts/build-icon.sh contacts`.

### Why the permissions belong to this app

As with the other apps, it gives up the responsibility macOS charges to whatever started it and launches itself again under its own identity, so Contacts and Automation are granted once, to "Apple Contacts MCP", whichever agent starts it. Start it by its real path or through a script that `exec`s it, not through a symbolic link.

## How it works

- **Cards, groups and accounts** go through Contacts.framework (`CNContactStore`, `CNSaveRequest`), with the cards read one by one (not unified) so each value stays on the card it came from. A small Objective-C target, `ContactsShim`, calls the framework's private parts Contacts.app uses: the alerts, Downtime, name order, photo crop, link preferences, the full-text search, vCard export with notes, restoring a card under its old id, and the name settings. Saves are tagged with this app as their author, so `contact_changes` can leave them out.
- **Screen Time.** Contacts.framework treats a card allowed during Downtime as read-only to other apps (CNErrorDomain 206). This app saves such cards as Contacts.app does, telling the framework to ignore guardian restrictions, but only for those cards and never in an account a guardian manages (Screen Time for a child), where the refusal stands. Contacts' AppleScript cannot save such a card at all: its save fails, and Contacts then keeps that change and every later one unsaved until it quits. So this app never writes one through AppleScript: it refuses to change the note of a contact allowed during Downtime (or anything else about it while it has a note), adds it to groups through the framework, and refuses to take it out of one; a contact with a note cannot be allowed during Downtime from here, and one restored with a note comes back without that allowance. Every AppleScript write also checks that Contacts saved it, and says so when Contacts is stuck.
- **Smart lists, distribution lists, linking, the default account and syncing** go through AddressBook.framework, which Contacts.app still uses for them. Its smart-list rules (`ABSearchElement`) are translated to and from the `criteria` above.
- **Notes and group members** go through Contacts' AppleScript, compiled once and called by Apple event; see [Notes](#notes). Group members are added this way because a card just saved by another process is not yet in Contacts.app's own copy, so members of new cards are added through Contacts.framework first.
- **Uploads.** Contacts' own daemon uploads every change. The app watches each card's CardDAV ETag (Contacts.framework's `externalModificationTag`), which the server renews when it accepts the card, then waits for the card to settle, since iCloud may hand it back changed.
- **Versions** are a hash of the contact as `read_contact` shows it, without its groups and times.
- **What needs no Contacts** is in its own target, `ContactsModel`: the tools as agents see them, the commands, dates, labels, the smart-list rules, the plan for changing a linked contact's lists, versions and the write guard. `ContactsComponent` gives each tool what it does. The unit tests (`ContactsModelTests`) build against `ContactsModel` only.
- The reverse-engineering notes are in [RE-FINDINGS-contacts.md](RE-FINDINGS-contacts.md) (in Chinese).

## Tests

```bash
/usr/bin/python3 -I scripts/e2e.py contacts                                # the installed app, against your real contacts
/usr/bin/python3 -I scripts/e2e.py contacts dist/AppleContactsMCP.app/Contents/MacOS/AppleContactsMCP
```

The checks run the tools over stdio and the main commands, 80 checks in all, with the write guard (`APPLE_CONTACTS_MCP_WRITE_GUARD=agent test e2e`) limiting writes to contacts, groups and smart lists whose names start with `agent test e2e`. They make throwaway contacts in the default account (iCloud, so your other devices see them come and go) with most fields, a note, a photo, Emergency Bypass and Downtime, links, a group and a smart list; check uploads, versions, search, linked contacts, merging, deleting and restoring, import (including replace) and export; read `find_duplicates` and `settings`; and at the end delete all of it and the copies kept. `set_my_card`, `manage_accounts` and changes to `settings` are left out, since they change your own setup. Run them against a signed build (`build-app.sh`), which holds the permissions; a bare `swift build` executable has neither. `swift test` checks the dates, labels, the linked-contact plan, versions, the write guard, the smart-list rules, and that the commands match the tools.

## Not possible

- **Pronouns.** Contacts keeps them encrypted, readable only by apps with Apple's entitlement.
- **Favorites, blocking, Emergency Contacts, Siri Suggestions in Contacts.** They belong to Phone, the block list and Health, each behind an entitlement this app cannot have. (Emergency Bypass, a field of the card, is supported.)
- **Contact Posters, Name and Photo Sharing.** The poster's picture is read; making posters and sharing are done by Phone and Messages.
- **Family members' accounts.** A child's contacts that Family Sharing shows on the parent's Mac come from a service (FamilyCircle) open only to Apple's apps.
- **Adding or removing an account, turning Contacts on or off for one.** System Settings → Internet Accounts.
- **Printing** (lists, envelopes, labels, pocket address book), **CSV and LDIF import**, and Contacts' **duplicate review** while importing. They live in Contacts.app itself, not in its frameworks; `import_contacts` has its own handling of duplicates instead.
- **Smart lists that sync, and distribution choices on other devices.** Contacts keeps both on this Mac.
- **The note of a contact allowed during Screen Time's Downtime**, anything else about one that has a note, taking one out of a group, and allowing a contact that has a note. Contacts' AppleScript cannot save such a card, and the framework hides notes; change these in Contacts itself.
