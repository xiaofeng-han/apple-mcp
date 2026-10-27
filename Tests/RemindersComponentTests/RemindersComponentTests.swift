import Foundation
import Testing
import Wire
@testable import AppCore
@testable import RemindersComponent

/// What the shared base takes from Reminders agrees with Reminders' tools. Made without Product.current
/// (other suites set it), so the deletion log is a temporary one.
@MainActor
@Suite struct RemindersComponentTests {
    let tools: [Tool]

    init() {
        let log = DeletionLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("deleted-\(UUID().uuidString).json"))
        let store = RemindersStore(writeGuard: nil, deletionLog: log)
        tools = readTools(store) + writeTools(store) + organizeTools(store)
    }

    var names: [String] { tools.map(\.name) }

    @Test func toolNamesAreUnique() {
        #expect(Set(names).count == names.count)
    }

    @Test func everyCommandRunsATool() {
        for route in RemindersComponent.cli.routes {
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

    @Test func everyToolHasAChineseTitle() {
        #expect(Set(RemindersComponent.chineseToolTitles.keys) == Set(names))
    }

    @Test func defaultVerbsAreCommands() {
        for (noun, verb) in RemindersComponent.cli.defaultVerbs {
            #expect(RemindersComponent.cli.routes.contains { $0.noun == noun && $0.verb == verb }, "\(noun) \(verb)")
        }
    }

    @Test func identity() {
        let product = RemindersComponent.product
        #expect([product.command, product.serverName, product.bundleID, product.appName, product.environmentPrefix]
            == ["apple-reminders-mcp", "apple-reminders", "com.xiaofeng.apple-reminders-mcp", "AppleRemindersMCP", "APPLE_REMINDERS_MCP"])
    }
}
