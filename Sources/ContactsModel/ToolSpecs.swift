import Agents
import Foundation
import Wire

/// What agents see of a tool: its name, title, description, input and effect. ContactsComponent adds
/// what each one does; the specs are here so the tests can check them against the commands without
/// Contacts.
package struct ToolSpec: Sendable {
    package let name: String
    package let title: String
    package let summary: String
    package let input: JSON
    package let effect: Tool.Effect

    package init(_ name: String, title: String, summary: String, input: JSON, effect: Tool.Effect) {
        self.name = name
        self.title = title
        self.summary = summary
        self.input = input
        self.effect = effect
    }
}

extension Tool {
    package init(_ spec: ToolSpec, run: @escaping @Sendable ([String: JSON]) async throws -> ToolAnswer) {
        self.init(spec.name, title: spec.title, summary: spec.summary, input: spec.input, effect: spec.effect, run: run)
    }
}

package enum ContactsTools {
    /// Apple Contacts MCP's identity (see Agents' Product).
    package static let product = Product(name: "Apple Contacts MCP", bundleID: "com.xiaofeng.apple-contacts-mcp", appName: "AppleContactsMCP",
                                         command: "apple-contacts-mcp", serverName: "apple-contacts", environmentPrefix: "APPLE_CONTACTS_MCP",
                                         subject: "Contacts", chineseSubject: "通讯录")

    /// The tools' titles in Chinese, for the Tools tab.
    package static let chineseTitles = [
        "overview": "通讯录概览",
        "find_contacts": "查找联系人",
        "read_contact": "读取联系人",
        "read_photo": "查看头像或海报",
        "list_groups": "列出分组和智能分组",
        "find_duplicates": "查找重复的联系人",
        "contact_changes": "查看最近的改动",
        "create_contact": "新建联系人",
        "update_contact": "修改联系人",
        "delete_contact": "删除联系人",
        "restore_contact": "恢复删除的联系人",
        "manage_group": "管理分组",
        "manage_smart_list": "管理智能分组",
        "link_contacts": "链接或取消链接卡片",
        "merge_contacts": "合并联系人",
        "set_my_card": "设为我的名片",
        "manage_accounts": "设置默认账户或立即同步",
        "import_contacts": "导入 vCard",
        "export_contacts": "导出联系人",
        "settings": "通讯录设置",
    ]

    static let placeLabels = "home, work, school, other, or any text"

    static let waitHelp = Schema.flag("Wait until iCloud (or the account's server) has it, usually 10–15 seconds and up to 45 (90 with a photo); default true. false answers once it is saved on this Mac")

    static func labeled(_ about: String, value: String, labels: String) -> JSON {
        Schema.list(of: Schema.object(["label": Schema.text(labels), "value": Schema.text(value)], required: ["value"]), about)
    }

    /// The contact fields create_contact and update_contact share. A list (phones, emails, …) replaces
    /// the whole list; null (or [] for a list) clears a field.
    static let contactFields: [String: JSON] = [
        "type": Schema.choice(["person", "company"], "A person, or a company (Contacts' Mark as a Company: shown by its organization)"),
        "prefix": Schema.clearable(Schema.text("Name prefix (Dr., Ms., …)")),
        "first_name": Schema.clearable(Schema.text("First (given) name")),
        "middle_name": Schema.clearable(Schema.text("Middle name")),
        "last_name": Schema.clearable(Schema.text("Last (family) name")),
        "maiden_name": Schema.clearable(Schema.text("Maiden name (previous family name)")),
        "suffix": Schema.clearable(Schema.text("Name suffix (Jr., III, …)")),
        "nickname": Schema.clearable(Schema.text("Nickname")),
        "phonetic_first_name": Schema.clearable(Schema.text("Phonetic first name (how it is said)")),
        "phonetic_middle_name": Schema.clearable(Schema.text("Phonetic middle name")),
        "phonetic_last_name": Schema.clearable(Schema.text("Phonetic last name")),
        "organization": Schema.clearable(Schema.text("Company")),
        "phonetic_organization": Schema.clearable(Schema.text("Phonetic company")),
        "department": Schema.clearable(Schema.text("Department")),
        "job_title": Schema.clearable(Schema.text("Job title")),
        "name_order": Schema.choice(["default", "given_first", "family_first"], "Name order for this card (Card > Reorder Last Name Before First)"),
        "note": Schema.clearable(Schema.text("The note: plain text, up to about 150,000 characters (iCloud's limit)")),
        "phones": Schema.clearable(labeled("Phone numbers; replaces them all", value: "Phone number",
                                           labels: "mobile, iPhone, home, work, school, main, home fax, work fax, pager, Apple Watch, other, or any text")),
        "emails": Schema.clearable(labeled("Email addresses; replaces them all", value: "Email address", labels: "home, work, school, iCloud, other, or any text")),
        "urls": Schema.clearable(labeled("Web addresses; replaces them all", value: "URL", labels: "homepage, home, work, school, other, or any text")),
        "addresses": Schema.clearable(Schema.list(of: Schema.object([
            "label": Schema.text(placeLabels), "street": Schema.text("Street; lines separated by \\n"),
            "sub_locality": Schema.text("District or neighborhood"), "city": Schema.text("City"),
            "sub_administrative_area": Schema.text("County"), "state": Schema.text("State, province or region"),
            "postal_code": Schema.text("ZIP or postal code"), "country": Schema.text("Country name"),
            "country_code": Schema.text("ISO country code (us, cn, de, …); it sets the address layout"),
        ]), "Postal addresses; replaces them all")),
        "dates": Schema.clearable(Schema.list(of: Schema.object([
            "label": Schema.text("anniversary, other, or any text"),
            "value": Schema.text("2015-06-01, or 06-01 for a date that comes every year"),
        ], required: ["value"]), "Dates other than the birthday; replaces them all")),
        "related_names": Schema.clearable(labeled("Related people; replaces them all", value: "Their name", labels: """
            mother, father, parent, spouse, partner, child, son, daughter, brother, sister, friend, manager, assistant, \
            mother in law, brother in law, … (any of Contacts' 200-odd relations, in words), or any text
            """)),
        "social_profiles": Schema.clearable(Schema.list(of: Schema.object([
            "label": Schema.text(placeLabels), "service": Schema.text("Twitter, Facebook, LinkedIn, Flickr, Myspace, Sina Weibo, Tencent Weibo, Yelp, or any service"),
            "username": Schema.text("User name"), "user_id": Schema.text("The service's user identifier"), "url": Schema.text("Profile URL"),
        ]), "Social profiles; replaces them all")),
        "instant_messages": Schema.clearable(Schema.list(of: Schema.object([
            "label": Schema.text(placeLabels), "service": Schema.text("Skype, Jabber, QQ, WeChat, MSN, Yahoo, ICQ, AIM, Facebook, Gadu-Gadu, Google Talk, or any service"),
            "username": Schema.text("User name"),
        ], required: ["username"]), "Instant-message addresses; replaces them all")),
        "birthday": Schema.clearable(Schema.text("1990-05-17, or 05-17 when the year is not known")),
        "other_birthday": Schema.clearable(Schema.any("""
            A birthday in another calendar (Contacts' lunar birthday): {calendar: chinese, hebrew, islamic, … , \
            year, month, day, leap_month}
            """)),
        "photo": Schema.clearable(Schema.text("Absolute path of an image file (JPEG, PNG, HEIC) to use as the photo; null removes the photo")),
        "photo_crop": ["type": "array", "items": ["type": "integer"], "minItems": 4, "maxItems": 4,
                       "description": "With photo: the part of it shown, [x, y, width, height] in the image's pixels, x and y from its top left; default the centered square"],
        "ringtone": Schema.clearable(Schema.text("Call ringtone: a tone id (system:Opening, …), <default> or <none>")),
        "text_tone": Schema.clearable(Schema.text("Text tone: a tone id (texttone:Note, …), <default> or <none>")),
        "emergency_bypass": Schema.choice(["off", "calls", "texts", "both"], "Let calls and/or texts from them sound even when muted or in a Focus"),
        "downtime_allowed": Schema.flag("Screen Time: they can reach the user during Downtime"),
    ]

    package static let overview = ToolSpec("overview", title: "Contacts overview",
        summary: """
            The accounts (iCloud, Google, On My Mac, …) with how many cards each holds and which one new \
            contacts go to, how many contacts there are (cards linked across accounts count once), the groups \
            and smart lists, and the My Card.
            """,
        input: Schema.object([:]), effect: .reads)

    package static let findContacts = ToolSpec("find_contacts", title: "Find contacts",
        summary: """
            Finds contacts as Contacts' search field does: every word of query must appear somewhere on the \
            card (any name, company, job, phones, emails, addresses, URLs, social profiles, related names, the \
            note), case and accents ignored. Narrow by phone or email (whole value), group (nested groups \
            included), smart list, account and person or company; or pass criteria (smart-list rules) to find \
            what a smart list would hold. Sorted as Contacts sorts them; each with its id and version.
            """,
        input: Schema.object([
            "query": Schema.text("Words that must all appear on the card"),
            "phone": Schema.text("A phone number, in any format"),
            "email": Schema.text("An email address"),
            "group": Schema.text("Only members of this group (name or id), including its nested groups"),
            "smart_list": Schema.text("Only what this smart list holds (name or id)"),
            "account": Schema.text("Only cards in this account (name or id)"),
            "type": Schema.choice(["person", "company"], "Only people or only companies"),
            "criteria": ["type": "object", "description": .string(Criteria.help)],
            "limit": Schema.whole("Default 50, at most 500"),
            "offset": Schema.whole("Skip this many, for the next page"),
        ]), effect: .reads)

    package static let readContact = ToolSpec("read_contact", title: "Read contacts",
        summary: """
            Reads contacts in full (up to 20): every field, the note, the groups it is in, whether it has a \
            photo or poster, its tones, and its cards (one per account when linked: which account, which one \
            gives the name and photo), with the version update_contact and delete_contact take.
            """,
        input: Schema.object([
            "id": Schema.text("Contact or card id"),
            "ids": Schema.texts("Several, up to 20"),
        ]), effect: .reads)

    package static let readPhoto = ToolSpec("read_photo", title: "Look at a contact's photo",
        summary: "A contact's photo (as shown, or the full image it is cropped from), or the picture of its poster (Contact Poster).",
        input: Schema.object([
            "id": Schema.text("Contact or card id"),
            "which": Schema.choice(["photo", "full", "poster"], "photo: as Contacts shows it (default); full: the whole image; poster: the poster's picture"),
        ], required: ["id"]), effect: .reads)

    package static let listGroups = ToolSpec("list_groups", title: "List groups and smart lists",
        summary: """
            The groups by account, nested as in Contacts' sidebar, with how many cards each holds, and the \
            smart lists with their rules. With group: its members, nested groups included or not, and for a \
            group the email, phone and address each member is reached by (its distribution list).
            """,
        input: Schema.object([
            "group": Schema.text("A group or smart list (name or id): list its members"),
            "nested": Schema.flag("With group: include the members of its nested groups"),
        ]), effect: .reads)

    package static let findDuplicates = ToolSpec("find_duplicates", title: "Find duplicate contacts",
        summary: """
            Finds cards that look like the same person, as Contacts' Look for Duplicates does: the same name \
            in the same account, or (with by: email_or_phone) a shared email address or phone number. Each \
            set lists the cards; merge_contacts merges one set.
            """,
        input: Schema.object([
            "by": Schema.choice(["name", "email_or_phone"], "Default name"),
            "account": Schema.text("Only this account (name or id)"),
        ]), effect: .reads)

    package static let contactChanges = ToolSpec("contact_changes", title: "What changed in Contacts",
        summary: """
            The contacts and groups added, changed, linked or deleted since a token (from Contacts' change \
            history), on any device; without since, only the current token, to pass next time. Leaves out \
            the saves this app made through Contacts' framework unless include_own; notes, group members, \
            links and smart lists this app changes through Contacts itself show like any other change.
            """,
        input: Schema.object([
            "since": Schema.text("The token a previous call gave"),
            "include_own": Schema.flag("Include the saves this app made through Contacts' framework"),
        ]), effect: .reads)

    package static let createContact = ToolSpec("create_contact", title: "Create a contact",
        summary: """
            Creates a person or a company with any of the fields, in an account (default: the one Contacts \
            puts new cards in) and in groups. Contacts uploads it to iCloud (or the account's server); the \
            answer says once it has.
            """,
        input: Schema.object(contactFields.merging([
            "account": Schema.text("Account name or id; default Contacts' default account"),
            "groups": Schema.texts("Groups to put it in (name or id), in the same account"),
            "wait": waitHelp,
        ]) { $1 }), effect: .writes)

    package static let updateContact = ToolSpec("update_contact", title: "Update a contact",
        summary: """
            Changes only the fields given: null clears one, a list (phones, emails, …) replaces the whole \
            list. Pass the version read_contact or find_contacts gave; a contact changed since is refused. A \
            contact linked across accounts keeps each value on the card it is on; new values go to the card \
            that gives its name, or to card.
            """,
        input: Schema.object(contactFields.merging([
            "id": Schema.text("Contact or card id"),
            "version": Schema.text("The version read_contact or find_contacts gave"),
            "card": Schema.text("For a linked contact: the card (id) new values and single fields go to"),
            "wait": waitHelp,
        ]) { $1 }, required: ["id", "version"]), effect: .writes)

    package static let deleteContact = ToolSpec("delete_contact", title: "Delete a contact",
        summary: """
            Deletes a contact (all its cards when it is linked, or only card) from every device: Contacts has \
            no Recently Deleted, so this app keeps a copy for 30 days and restore_contact brings it back. Ask \
            the user first.
            """,
        input: Schema.object([
            "id": Schema.text("Contact or card id"),
            "version": Schema.text("The version read_contact or find_contacts gave"),
            "card": Schema.text("Only this card of a linked contact"),
        ], required: ["id", "version"]), effect: .deletes)

    package static let restoreContact = ToolSpec("restore_contact", title: "Restore a deleted contact",
        summary: """
            Lists the contacts this app deleted in the last 30 days, or brings one back with its id, fields, \
            note, photo and groups, in its account.
            """,
        input: Schema.object(["id": Schema.text("A deleted card's id; without it, list them")]), effect: .writes)

    package static let manageGroup = ToolSpec("manage_group", title: "Manage a group",
        summary: """
            Creates a group (in an account, optionally inside another group and with members), renames or \
            deletes one (its contacts stay), adds or removes members, nests a group in another or takes it \
            out, and chooses which email, phone or address a member is reached by in the group (its \
            distribution list).
            """,
        input: Schema.object([
            "action": Schema.choice(["create", "rename", "delete", "add_members", "remove_members", "nest", "unnest", "distribution"], "What to do"),
            "group": Schema.text("The group (name or id); for create, the new group's name"),
            "new_name": Schema.text("rename: the new name"),
            "account": Schema.text("create: the account (name or id); default Contacts' default account"),
            "parent": Schema.text("create: put it inside this group; nest/unnest: the outer group (name or id)"),
            "members": Schema.texts("create, add_members, remove_members: contact or card ids"),
            "member": Schema.text("distribution: the member (contact or card id)"),
            "email": Schema.text("distribution: the member's email address the group uses"),
            "phone": Schema.text("distribution: the member's phone number the group uses"),
            "address": Schema.text("distribution: the label of the member's postal address the group uses"),
        ], required: ["action", "group"]), effect: .deletes)

    package static let manageSmartList = ToolSpec("manage_smart_list", title: "Manage a smart list",
        summary: """
            Creates, changes or deletes a smart list: a list Contacts fills itself with every contact that \
            matches its rules. Contacts keeps smart lists on this Mac only (On My Mac); they do not sync.
            """,
        input: Schema.object([
            "action": Schema.choice(["create", "update", "delete"], "What to do"),
            "smart_list": Schema.text("The smart list (name or id); for create, the new name"),
            "new_name": Schema.text("update: the new name"),
            "criteria": ["type": "object", "description": .string(Criteria.help)],
            "highlight": Schema.flag("Highlight it when one of its contacts changes (Contacts' option)"),
        ], required: ["action", "smart_list"]), effect: .deletes)

    package static let linkContacts = ToolSpec("link_contacts", title: "Link or unlink cards",
        summary: """
            Links cards of the same person (usually in different accounts) into one contact, as Contacts does \
            with same-name cards; unlinks a card, or all of a contact's cards; or chooses which linked card \
            gives the contact its name (prefer_name) or its photo (prefer_photo).
            """,
        input: Schema.object([
            "action": Schema.choice(["link", "unlink", "prefer_name", "prefer_photo"], "What to do"),
            "ids": Schema.texts("link: the contacts or cards to link (two or more)"),
            "id": Schema.text("unlink: a card (only that one) or a contact (all its cards); prefer_name, prefer_photo: the card"),
        ], required: ["action"]), effect: .writes)

    package static let mergeContacts = ToolSpec("merge_contacts", title: "Merge contacts",
        summary: """
            Merges cards into the first one, as Contacts' Merge Selected Cards does: every phone, email, address \
            and other value is kept, empty fields are filled, notes are joined, the photo is kept, the others' \
            groups are added, and the other cards are deleted (this app keeps a copy for 30 days). Cards in \
            other accounts are linked instead. Ask the user first.
            """,
        input: Schema.object([
            "ids": Schema.texts("The cards (or contacts) to merge; the first one is kept"),
            "versions": Schema.texts("Their versions, from read_contact or find_contacts, in the same order"),
        ], required: ["ids", "versions"]), effect: .deletes)

    package static let setMyCard = ToolSpec("set_my_card", title: "Set the My Card",
        summary: """
            Makes a contact the user's own card (Card > Make This My Card), which Safari AutoFill, Messages' \
            Name and Photo Sharing and other apps use. Confirm with the user first.
            """,
        input: Schema.object(["id": Schema.text("Contact or card id")], required: ["id"]), effect: .writes)

    package static let manageAccounts = ToolSpec("manage_accounts", title: "Default account and sync",
        summary: """
            Sets the account new contacts go to (iCloud, Google or On My Mac), or asks Contacts to sync \
            accounts with their servers now (Refresh Accounts). Adding or removing an account is done in \
            System Settings → Internet Accounts.
            """,
        input: Schema.object([
            "action": Schema.choice(["set_default", "sync"], "What to do"),
            "account": Schema.text("set_default: the account (name or id); sync: one account, default all"),
        ], required: ["action"]), effect: .writes)

    package static let importContacts = ToolSpec("import_contacts", title: "Import vCards",
        summary: """
            Imports a .vcf file (one or more vCards, with notes and photos) into an account and optionally a \
            group. A card with the same name as an existing one in that account is a duplicate: skipped and \
            listed (default), merged into it (update), added anyway (keep_both) or put in its place (replace: \
            the old card is deleted, kept 30 days, and the new one joins its groups and links), as in Contacts' \
            import review.
            """,
        input: Schema.object([
            "path": Schema.text("Absolute path of the .vcf file"),
            "account": Schema.text("Account (name or id); default Contacts' default account"),
            "group": Schema.text("Also add the imported contacts to this group (name or id)"),
            "duplicates": Schema.choice(["skip", "update", "keep_both", "replace"], "What to do with a card whose name exists already; default skip"),
        ], required: ["path"]), effect: .deletes)

    package static let exportContacts = ToolSpec("export_contacts", title: "Export contacts",
        summary: """
            Writes contacts to a .vcf file, as Contacts' File > Export vCard does: chosen ones, a group's or \
            smart list's, those matching a query, the My Card (Share My Card), or all. vCard 3.0 (or 2.1), \
            with notes and photos unless turned off.
            """,
        input: Schema.object([
            "to": Schema.text("Absolute path of the .vcf file to write (it must not exist)"),
            "ids": Schema.texts("These contacts"),
            "group": Schema.text("A group's or smart list's members (name or id)"),
            "query": Schema.text("Contacts matching these words, as find_contacts"),
            "my_card": Schema.flag("The My Card"),
            "version": Schema.choice(["3.0", "2.1"], "Default 3.0"),
            "notes": Schema.flag("Include notes (default true)"),
            "photos": Schema.flag("Include photos (default true)"),
        ], required: ["to"]), effect: .writes)

    package static let settings = ToolSpec("settings", title: "Contacts settings",
        summary: """
            Contacts' settings: sort order, name display and short names, the address format, vCard export \
            options and the private My Card, and Show Siri Suggestions. With a field, changes that setting \
            (sort_by, address_format, vcard_version, vcard_notes, vcard_photos, private_my_card); name order, \
            short names and nicknames are macOS-wide and read only here.
            """,
        input: Schema.object([
            "sort_by": Schema.choice(["first_name", "last_name"], "Sort contacts by"),
            "address_format": Schema.text("Country whose address layout Contacts uses (ISO code: us, cn, de, …)"),
            "vcard_version": Schema.choice(["3.0", "2.1"], "vCard format for export"),
            "vcard_notes": Schema.flag("Export notes in vCards"),
            "vcard_photos": Schema.flag("Export photos in vCards"),
            "private_my_card": Schema.flag("Leave out the My Card's private fields when it is shared"),
        ]), effect: .writes)

    package static let all = [overview, findContacts, readContact, readPhoto, listGroups, findDuplicates, contactChanges,
                              createContact, updateContact, deleteContact, restoreContact, manageGroup, manageSmartList,
                              linkContacts, mergeContacts, setMyCard, manageAccounts, importContacts, exportContacts, settings]
}
