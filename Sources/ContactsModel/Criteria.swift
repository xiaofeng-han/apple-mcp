import Foundation
import Wire

/// Smart-list criteria, as Contacts' smart-list editor builds them: {match: all|any, rules: [{field,
/// op, value}]}, where a rule may itself be {match, rules}. Checked here so a mistake reaches the agent
/// as a clear message instead of an AddressBook exception.
package enum Criteria {
    package static let textOps = ["contains", "not_contains", "is", "is_not", "is_set", "is_not_set"]
    package static let handleOps = textOps + ["starts_with", "ends_with"]
    package static let dateOps = ["next_days", "within_days", "not_within_days", "is_set", "is_not_set"]

    /// Each field and the comparisons it takes, as the editor offers them.
    package static let fields: [String: [String]] = {
        var fields: [String: [String]] = [
            "any": ["contains", "not_contains"],
            "name": textOps,
            "address": ["contains", "not_contains", "is_set", "is_not_set"],
            "modified": ["changed_within_days", "not_changed_within_days", "after"],
            "group": ["member_of", "not_member_of"],
        ]
        for field in ["first_name", "last_name", "middle_name", "phonetic_first_name", "phonetic_last_name", "phonetic_middle_name",
                      "nickname", "organization", "department", "job_title", "note", "street", "city", "state", "zip", "country"] {
            fields[field] = textOps
        }
        for field in ["phone", "email", "url", "instant_message"] { fields[field] = handleOps }
        for field in ["birthday", "anniversary", "date"] { fields[field] = dateOps }
        return fields
    }()

    package static let help = """
        {match: all|any, rules: [{field, op, value}]}; a rule may itself be {match, rules}. Fields: any (any \
        text on the card; ops contains, not_contains); name, first_name, last_name, middle_name, nickname, \
        organization, department, job_title, note, phone, email, url, instant_message, street, city, state, \
        zip, country (ops contains, not_contains, is, is_not, is_set, is_not_set; phone/email/url/\
        instant_message also starts_with, ends_with); address (contains, not_contains, is_set, is_not_set); \
        birthday, anniversary, date (next_days, within_days, not_within_days with a number of days; is_set, \
        is_not_set); modified (changed_within_days, not_changed_within_days with days; after with \
        2026-10-21); group (member_of, not_member_of a group or smart list, by name or id)
        """

    /// Checks criteria and turns them into the plain dictionary the shim takes. `group` resolves a
    /// group or smart list name or id to its id.
    package static func validated(_ value: JSON, depth: Int = 0, group: (String) throws -> String) throws -> [String: Any] {
        guard depth < 4 else { throw BadInput("criteria nest too deep") }
        guard let object = value.object else { throw BadInput("criteria must be an object {match, rules}") }
        let match = object["match"]?.string ?? "all"
        guard ["all", "any"].contains(match) else { throw BadInput("criteria match must be all or any") }
        guard let rules = object["rules"]?.array, !rules.isEmpty else { throw BadInput("criteria need a non-empty rules list") }
        if let unknown = object.keys.sorted().first(where: { !["match", "rules"].contains($0) }) {
            throw BadInput("criteria.\(unknown) is not known; use match and rules")
        }
        let checked: [[String: Any]] = try rules.map { rule in
            guard let fields = rule.object else { throw BadInput("each rule must be an object {field, op, value}") }
            if fields["rules"] != nil { return try validated(rule, depth: depth + 1, group: group) }
            if let unknown = fields.keys.sorted().first(where: { !["field", "op", "value"].contains($0) }) {
                throw BadInput("rule.\(unknown) is not known; use field, op and value")
            }
            guard let field = fields["field"]?.string, let ops = Self.fields[field] else {
                throw BadInput("rule field must be one of: \(Self.fields.keys.sorted().joined(separator: ", "))")
            }
            guard let op = fields["op"]?.string, ops.contains(op) else {
                throw BadInput("\(field) takes the ops: \(ops.joined(separator: ", "))")
            }
            var result: [String: Any] = ["field": field, "op": op]
            if ["is_set", "is_not_set"].contains(op) { return result }
            let value = fields["value"]
            if op.hasSuffix("_days") {
                guard let days = value?.int, (1...3650).contains(days) else { throw BadInput("\(field) \(op) takes a number of days from 1 to 3650") }
                result["value"] = days
            } else if op == "after" {
                guard let day = value?.string, ContactDate.parse(day)?.year != nil else { throw BadInput("modified after takes a day like 2026-10-21") }
                result["value"] = day
            } else if field == "group" {
                guard let name = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    throw BadInput("group \(op) takes a group or smart list name or id")
                }
                result["value"] = try group(name)
            } else {
                guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw BadInput("\(field) \(op) takes a text value that is not only spaces")
                }
                result["value"] = text
            }
            return result
        }
        return ["match": match, "rules": checked]
    }
}
