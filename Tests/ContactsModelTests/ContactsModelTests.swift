import Foundation
import Testing
import Wire
@testable import AppCore
@testable import ContactsModel

/// What the shared base takes from Contacts agrees with Contacts' tools as agents see them. Made
/// without Product.current (other suites set it), and without Contacts.
@Suite struct ContactsToolsTests {
    let tools = ContactsTools.all

    var names: [String] { tools.map(\.name) }

    @Test func toolNamesAreUnique() {
        #expect(Set(names).count == names.count)
    }

    @Test func everyCommandRunsATool() {
        for route in ContactsCommands.cli.routes {
            guard let tool = tools.first(where: { $0.name == route.tool }) else {
                Issue.record("\(route.command) runs \(route.tool), which is not a tool")
                continue
            }
            let fields = Set((tool.input["properties"]?.object ?? [:]).keys)
            let named = Set(route.fixed.keys).union(route.positional.map(\.key)).union(route.only ?? []).union(route.required)
                .union(route.abouts.keys).union(route.stdin).union(route.fallback.fields.keys).union(route.fallback.unless)
            #expect(named.isSubset(of: fields), "\(route.command): \(named.subtracting(fields).sorted())")
        }
    }

    @Test func fixedActionsAreOnesTheToolTakes() {
        for route in ContactsCommands.cli.routes {
            guard let tool = tools.first(where: { $0.name == route.tool }) else { continue }
            for (key, value) in route.fixed {
                let allowed = tool.input["properties"]?[key]?["enum"]?.array ?? []
                #expect(allowed.contains(value), "\(route.command): \(key) \(value)")
            }
        }
    }

    @Test func everyToolHasACommand() {
        let commanded = Set(ContactsCommands.cli.routes.map(\.tool))
        #expect(commanded == Set(names), "no command: \(Set(names).subtracting(commanded).sorted())")
    }

    @Test func everyToolHasAChineseTitle() {
        #expect(Set(ContactsTools.chineseTitles.keys) == Set(names))
    }

    @Test func defaultVerbsAreCommands() {
        for (noun, verb) in ContactsCommands.cli.defaultVerbs {
            #expect(ContactsCommands.cli.routes.contains { $0.noun == noun && $0.verb == verb }, "\(noun) \(verb)")
        }
    }

    @Test func deletingToolsSayTheyDelete() {
        for name in ["delete_contact", "manage_group", "manage_smart_list", "merge_contacts", "import_contacts"] {
            #expect(tools.first { $0.name == name }?.effect == .deletes, "\(name)")
        }
    }

    @Test func identity() {
        let product = ContactsTools.product
        #expect([product.command, product.serverName, product.bundleID, product.appName, product.environmentPrefix]
            == ["apple-contacts-mcp", "apple-contacts", "com.xiaofeng.apple-contacts-mcp", "AppleContactsMCP", "APPLE_CONTACTS_MCP"])
    }
}

@Suite struct ContactDateTests {
    @Test func gregorianDatesWithAndWithoutYear() {
        #expect(ContactDate.parse("1990-05-17")?.short == "1990-05-17")
        #expect(ContactDate.parse("05-17")?.short == "05-17")
        #expect(ContactDate.parse("--05-17")?.short == "05-17")
        #expect(ContactDate.parse("05-17")?.year == nil)
    }

    @Test func impossibleDaysAreRefused() {
        #expect(ContactDate.parse("2025-02-29") == nil)
        #expect(ContactDate.parse("2024-02-29") != nil)
        #expect(ContactDate.parse("02-29") != nil)
        #expect(ContactDate.parse("2026-04-31") == nil)
        #expect(ContactDate.parse("13-01") == nil)
        #expect(ContactDate.parse("1990") == nil)
        #expect(ContactDate.parse("90-05-17") == nil)
        #expect(ContactDate.parse("hello") == nil)
    }

    @Test func otherCalendarsHaveTheObjectForm() {
        let lunar = ContactDate(calendar: "chinese", month: 4, day: 23, leapMonth: true)
        #expect(lunar.short == nil)
        #expect(lunar.json == ["calendar": "chinese", "month": 4, "day": 23, "leap_month": true])
    }
}

@Suite struct LabelTests {
    let standard = ["_$!<Mobile>!$_", "_$!<Home>!$_", "_$!<HomeFAX>!$_", "_$!<HomePage>!$_", "iPhone", "iCloud",
                    "_$!<FatherInLaw>!$_", "_$!<GrandfatherFathersFather>!$_", "_$!<Anniversary>!$_"]

    @Test func storedLabelsReadAsWords() {
        #expect(Labels.friendly("_$!<Mobile>!$_") == "mobile")
        #expect(Labels.friendly("_$!<HomeFAX>!$_") == "home fax")
        #expect(Labels.friendly("_$!<HomePage>!$_") == "homepage")
        #expect(Labels.friendly("_$!<FatherInLaw>!$_") == "father in law")
        #expect(Labels.friendly("_$!<GrandfatherFathersFather>!$_") == "grandfather fathers father")
        #expect(Labels.friendly("iPhone") == "iPhone")
        #expect(Labels.friendly("Apple Watch") == "Apple Watch")
        #expect(Labels.friendly("my custom") == "my custom")
    }

    @Test func wordsBecomeTheStandardLabels() {
        #expect(Labels.stored("mobile", standard: standard) == "_$!<Mobile>!$_")
        #expect(Labels.stored("Home Fax", standard: standard) == "_$!<HomeFAX>!$_")
        #expect(Labels.stored("father-in-law", standard: standard) == "_$!<FatherInLaw>!$_")
        #expect(Labels.stored("iphone", standard: standard) == "iPhone")
        #expect(Labels.stored("homepage", standard: standard) == "_$!<HomePage>!$_")
        #expect(Labels.stored("apple watch", standard: standard + ["Apple Watch"]) == "Apple Watch")
        #expect(Labels.stored("Gym", standard: standard) == "Gym")
    }

    @Test func everyStandardLabelRoundTrips() {
        for label in standard {
            #expect(Labels.stored(Labels.friendly(label), standard: standard) == label, "\(label)")
        }
    }
}

@Suite struct MultiValuePlanTests {
    typealias Existing = MultiValuePlan.Existing

    @Test func valuesStayOnTheirCardsAndNewOnesGoToTheTarget() {
        let existing = [Existing(card: 0, id: "a", label: "home", key: "111"), Existing(card: 1, id: "b", label: "work", key: "222")]
        let steps = MultiValuePlan.steps(existing: existing, desired: [("home", "111"), ("work", "222"), ("mobile", "333")], target: 0)
        #expect(steps == [.keep(card: 0, id: "a", label: "home", desired: 0), .keep(card: 1, id: "b", label: "work", desired: 1), .add(card: 0, desired: 2)])
    }

    @Test func missingValuesAreRemovedAndLabelsChange() {
        let existing = [Existing(card: 0, id: "a", label: "home", key: "111"), Existing(card: 1, id: "b", label: "work", key: "222")]
        let steps = MultiValuePlan.steps(existing: existing, desired: [("mobile", "222")], target: 0)
        #expect(steps == [.keep(card: 1, id: "b", label: "mobile", desired: 0), .remove(card: 0, id: "a")])
    }

    @Test func duplicatesMatchOnce() {
        let existing = [Existing(card: 0, id: "a", label: nil, key: "x")]
        let steps = MultiValuePlan.steps(existing: existing, desired: [(nil, "x"), (nil, "x")], target: 0)
        #expect(steps == [.keep(card: 0, id: "a", label: nil, desired: 0), .add(card: 0, desired: 1)])
    }

    @Test func aValueOnTwoLinkedCardsStaysOnBoth() {
        // iCloud and Google both have the number; Contacts shows it once, and the agent adds another.
        let existing = [Existing(card: 0, id: "a", label: "mobile", key: "555"), Existing(card: 1, id: "b", label: "iPhone", key: "555")]
        let steps = MultiValuePlan.steps(existing: existing, desired: [("mobile", "555"), ("work", "777")], target: 0)
        #expect(steps == [.keep(card: 0, id: "a", label: "mobile", desired: 0), .add(card: 0, desired: 1),
                          .keep(card: 1, id: "b", label: "iPhone", desired: nil)])
    }

    @Test func aRepeatedValueOnOneCardIsStillRemoved() {
        let existing = [Existing(card: 0, id: "a", label: nil, key: "555"), Existing(card: 0, id: "b", label: nil, key: "555")]
        let steps = MultiValuePlan.steps(existing: existing, desired: [(nil, "555")], target: 0)
        #expect(steps == [.keep(card: 0, id: "a", label: nil, desired: 0), .remove(card: 0, id: "b")])
    }

    @Test func keys() {
        #expect(MultiValuePlan.phoneKey("+1 (555) 010-0001") == "+15550100001")
        #expect(MultiValuePlan.phoneKey("555.010.0001") == "5550100001")
        #expect(MultiValuePlan.textKey("  Jane@Example.COM ") == "jane@example.com")
    }
}

@Suite struct VersionTests {
    let contact: JSON = ["id": "1", "name": "Jane", "phones": [["label": "mobile", "value": "555"]], "note": "hi",
                         "groups": [["id": "g"]], "created": "2026-01-01T00:00:00Z", "modified": "2026-01-02T00:00:00Z"]

    func changed(_ key: String, _ value: JSON) -> JSON {
        var object = contact.object!
        object[key] = value
        return .object(object)
    }

    @Test func everyShownFieldCounts() {
        let version = Versions.of(contact)
        #expect(version.count == 12)
        #expect(Versions.of(changed("note", "bye")) != version)
        #expect(Versions.of(changed("phones", [["label": "home", "value": "555"]])) != version)
        #expect(Versions.of(changed("photo", true)) != version)
    }

    @Test func timestampsAndGroupsDoNot() {
        let version = Versions.of(contact)
        #expect(Versions.of(changed("modified", "2027-01-01T00:00:00Z")) == version)
        #expect(Versions.of(changed("groups", [])) == version)
        #expect(Versions.of(changed("version", "x")) == version)
    }
}

@Suite struct WriteGuardTests {
    @Test func namesMustStartWithAPrefix() {
        let guarded = WriteGuard("agent test, e2e")!
        #expect(guarded.allows("agent test One"))
        #expect(guarded.allows("Agent Test company"))
        #expect(guarded.allows("e2e thing"))
        #expect(!guarded.allows("Jane agent test"))
        #expect(!guarded.allows("Jane"))
        #expect(throws: ContactsError.self) { try guarded.check("Jane", what: "contacts") }
    }

    @Test func emptyMeansNone() {
        #expect(WriteGuard(nil) == nil)
        #expect(WriteGuard(" , ") == nil)
    }
}

@Suite struct CriteriaTests {
    func check(_ json: JSON) throws -> [String: Any] {
        try Criteria.validated(json) { name in
            guard name == "Family" else { throw BadInput("no \(name)") }
            return "G1:ABGroup"
        }
    }

    @Test func validRulesPassAndGroupsResolve() throws {
        let checked = try check(["match": "any", "rules": [
            ["field": "name", "op": "contains", "value": " jane "],
            ["field": "birthday", "op": "next_days", "value": 7],
            ["field": "group", "op": "member_of", "value": "Family"],
            ["match": "all", "rules": [["field": "phone", "op": "is_set"]]],
        ]])
        #expect(checked["match"] as? String == "any")
        let rules = checked["rules"] as? [[String: Any]] ?? []
        #expect(rules.count == 4)
        #expect(rules[0]["value"] as? String == "jane")
        #expect(rules[2]["value"] as? String == "G1:ABGroup")
        #expect(rules[3]["rules"] != nil)
    }

    @Test func mistakesAreRefused() {
        #expect(throws: BadInput.self) { try check(["rules": []]) }
        #expect(throws: BadInput.self) { try check(["rules": [["field": "colour", "op": "is", "value": "x"]]]) }
        #expect(throws: BadInput.self) { try check(["rules": [["field": "birthday", "op": "contains", "value": "x"]]]) }
        #expect(throws: BadInput.self) { try check(["rules": [["field": "birthday", "op": "next_days", "value": 0]]]) }
        #expect(throws: BadInput.self) { try check(["rules": [["field": "modified", "op": "after", "value": "05-17"]]]) }
        #expect(throws: BadInput.self) { try check(["rules": [["field": "group", "op": "member_of", "value": "Nope"]]]) }
        #expect(throws: BadInput.self) { try check(["match": "some", "rules": [["field": "any", "op": "contains", "value": "x"]]]) }
        #expect(throws: BadInput.self) { try check(["rules": [["field": "name", "op": "contains", "value": " \t\u{00A0} "]]]) }
        #expect(throws: BadInput.self) { try check(["rules": [["field": "address", "op": "is", "value": "Paris"]]]) }
    }
}
