@preconcurrency import Contacts
import ContactsModel
import Foundation
import Wire

/// Answers of writes: the contact as read_contact shows it, and whether it reached iCloud.
private func written(_ lead: String, _ written: ContactsStore.Written) -> ToolAnswer {
    var object = written.record.object ?? [:]
    switch written.uploaded {
    case true?: object["uploaded"] = true
    case false?: object["uploaded"] = false; object["upload_note"] = "Saved on this Mac; Contacts has not uploaded it yet and will keep trying."
    case nil: break
    }
    return .json(lead, .object(object))
}

@MainActor
func writeTools(_ store: ContactsStore) -> [Tool] {
    [
        Tool(ContactsTools.createContact) { fields in
            let input = Input(fields)
            let account = try input.text("account"), groups = try input.texts("groups") ?? [], wait = try input.flag("wait") ?? true
            return try await run(store) {
                let edit = try ContactEdit(fields, labels: store.standardLabels)
                return written("Created.", try await store.create(edit, account: account, groups: groups, wait: wait))
            }
        },

        Tool(ContactsTools.updateContact) { fields in
            let input = Input(fields)
            let id = try input.required("id"), version = try input.required("version"), card = try input.text("card"), wait = try input.flag("wait") ?? true
            var changes = fields
            for key in ["id", "version", "card", "wait"] { changes.removeValue(forKey: key) }
            return try await run(store) {
                let edit = try ContactEdit(changes, labels: store.standardLabels)
                return written("Updated.", try await store.update(id, version: version, edit: edit, card: card, wait: wait))
            }
        },

        Tool(ContactsTools.deleteContact) { fields in
            let input = Input(fields)
            let id = try input.required("id"), version = try input.required("version"), card = try input.text("card")
            return try await run(store) { .json("Deleted.", try await store.delete(id, version: version, card: card)) }
        },

        Tool(ContactsTools.restoreContact) { fields in
            let id = try Input(fields).text("id")
            return try await run(store) {
                guard let id else { return .json("", store.listDeleted()) }
                return .json("Restored.", try await store.restore(id))
            }
        },

        Tool(ContactsTools.manageGroup) { fields in
            let input = Input(fields)
            let action = try input.pick("action", from: ["create", "rename", "delete", "add_members", "remove_members", "nest", "unnest", "distribution"])
            guard let action else { throw BadInput("action is required") }
            let group = try input.required("group")
            return try await run(store) {
                switch action {
                case "create":
                    return .json("Created.", try await store.createGroup(group, account: try input.text("account"), parent: try input.text("parent"),
                                                                         members: try input.texts("members") ?? []))
                case "rename": return .json("Renamed.", try store.renameGroup(group, to: try input.required("new_name")))
                case "delete": return .json("Deleted.", try store.deleteGroup(group))
                case "add_members": return .json("Added.", try await store.changeMembers(group, add: true, ids: try input.texts("members") ?? []))
                case "remove_members": return .json("Removed.", try await store.changeMembers(group, add: false, ids: try input.texts("members") ?? []))
                case "nest", "unnest":
                    return .json("Done.", try store.nestGroup(group, parent: try input.required("parent"), nest: action == "nest"))
                default:
                    return .json("Done.", try await store.setDistribution(group, member: try input.required("member"), email: try input.text("email"),
                                                                         phone: try input.text("phone"), address: try input.text("address")))
                }
            }
        },

        Tool(ContactsTools.manageSmartList) { fields in
            let input = Input(fields)
            guard let action = try input.pick("action", from: ["create", "update", "delete"]) else { throw BadInput("action is required") }
            let list = try input.required("smart_list")
            let highlight = try input.flag("highlight"), newName = try input.text("new_name")
            return try await run(store) {
                let criteria = try fields["criteria"].flatMap { $0 == .null ? nil : $0 }.map { try store.criteria($0) }
                switch action {
                case "create":
                    guard let criteria else { throw BadInput("criteria is required to create a smart list") }
                    return .json("Created.", try store.createSmartList(list, criteria: criteria, highlight: highlight ?? false))
                case "update": return .json("Updated.", try store.updateSmartList(list, name: newName, criteria: criteria, highlight: highlight))
                default: return .json("Deleted.", try store.deleteSmartList(list))
                }
            }
        },

        Tool(ContactsTools.linkContacts) { fields in
            let input = Input(fields)
            guard let action = try input.pick("action", from: ["link", "unlink", "prefer_name", "prefer_photo"]) else { throw BadInput("action is required") }
            let ids = try input.texts("ids") ?? [], id = try input.text("id")
            return try await run(store) {
                switch action {
                case "link": return .json("Linked.", try await store.link(ids))
                case "unlink":
                    guard let id else { throw BadInput("id is required to unlink") }
                    return .json("Unlinked.", try await store.unlink(id))
                default:
                    guard let id else { throw BadInput("id (a card) is required") }
                    return .json("Done.", try await store.prefer(id, name: action == "prefer_name"))
                }
            }
        },

        Tool(ContactsTools.mergeContacts) { fields in
            let input = Input(fields)
            let ids = try input.texts("ids") ?? [], versions = try input.texts("versions") ?? []
            return try await run(store) { .json("Merged.", try await store.merge(ids, versions: versions)) }
        },

        Tool(ContactsTools.setMyCard) { fields in
            let id = try Input(fields).required("id")
            return try await run(store) { .json("This is now the My Card.", try await store.setMyCard(id)) }
        },

        Tool(ContactsTools.manageAccounts) { fields in
            let input = Input(fields)
            guard let action = try input.pick("action", from: ["set_default", "sync"]) else { throw BadInput("action is required") }
            let account = try input.text("account")
            return try await run(store) {
                if action == "sync" { return .json("", try store.sync(account)) }
                guard let account else { throw BadInput("account is required") }
                if let guardText = store.writeGuard { throw ContactsError("The default account cannot change while the write guard (\(guardText.description)) is set.") }
                return .json("Done.", try store.setDefaultAccount(account))
            }
        },

        Tool(ContactsTools.importContacts) { fields in
            let input = Input(fields)
            let path = try input.required("path")
            guard path.hasPrefix("/") else { throw BadInput("path must be absolute") }
            let account = try input.text("account"), group = try input.text("group")
            let choice = ContactsStore.DuplicateChoice(rawValue: try input.pick("duplicates", from: ["skip", "update", "keep_both", "replace"]) ?? "skip") ?? .skip
            return try await run(store) { .json("Imported.", try await store.importFile(path, account: account, group: group, duplicates: choice)) }
        },

        Tool(ContactsTools.exportContacts) { fields in
            let input = Input(fields)
            let to = try input.required("to")
            let ids = try input.texts("ids"), group = try input.text("group"), query = try input.text("query"), myCard = try input.flag("my_card") ?? false
            let version21 = (try input.pick("version", from: ["3.0", "2.1"])) == "2.1"
            let notes = try input.flag("notes") ?? true, photos = try input.flag("photos") ?? true
            return try await run(store) {
                var chosen: [String]
                if let ids {
                    chosen = ids
                } else if myCard {
                    guard let me = store.myCardIDs().first else { throw ContactsError("No My Card is set.") }
                    chosen = [me]
                } else if group != nil || query != nil {
                    var groupName: String?, smartList: String?
                    if let group {
                        switch try store.listing(group) {
                        case .group(let found): groupName = found.id
                        case .smartList(let list): smartList = list["id"] as? String
                        }
                    }
                    chosen = try await store.matching(FindFilters(query: query, phone: nil, email: nil, group: groupName, smartList: smartList,
                                                                  account: nil, type: nil, criteria: nil, limit: .max, offset: 0)).map(\.identifier)
                } else {
                    chosen = try store.unifiedContacts(nil, keys: [CNContactIdentifierKey as NSString]).map(\.identifier)
                }
                return .json("Exported.", try await store.export(chosen, to: to, version21: version21, notes: notes, photos: photos))
            }
        },

        Tool(ContactsTools.settings) { fields in
            var changes: [String: Any] = [:]
            let input = Input(fields)
            if let sort = try input.pick("sort_by", from: ["first_name", "last_name"]) { changes["sort_by"] = sort }
            if let format = try input.text("address_format") { changes["address_format"] = format }
            if let version = try input.pick("vcard_version", from: ["3.0", "2.1"]) { changes["vcard_version"] = version }
            for key in ["vcard_notes", "vcard_photos", "private_my_card"] { if let flag = try input.flag(key) { changes[key] = flag } }
            return try await run(store) {
                if changes.isEmpty { return .json("", store.settings()) }
                if let guardText = store.writeGuard { throw ContactsError("Settings cannot change while the write guard (\(guardText.description)) is set.") }
                return .json("Changed.", try store.changeSettings(changes))
            }
        },
    ]
}
