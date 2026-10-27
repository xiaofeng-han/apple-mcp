import Foundation
import Testing
import Wire
@testable import AppCore
@testable import NotesComponent

/// What the shared base takes from Notes agrees with Notes' tools. Made without Product.current
/// (other suites set it to another app), so the descriptions file is a temporary one.
@MainActor
@Suite struct NotesComponentTests {
    let tools: [Tool]

    init() {
        let store = NotesStore(writeGuard: nil)
        let descriptions = Descriptions(file: FileManager.default.temporaryDirectory.appendingPathComponent("descriptions-\(UUID().uuidString).json"))
        tools = readTools(store, descriptions) + attachmentTools(store) + writeTools(store)
    }

    var names: [String] { tools.map(\.name) }

    @Test func toolNamesAreUnique() {
        #expect(Set(names).count == names.count)
    }

    @Test func everyCommandRunsATool() {
        for route in NotesComponent.cli.routes {
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
        #expect(Set(NotesComponent.chineseToolTitles.keys) == Set(names))
    }

    @Test func defaultVerbsAreCommands() {
        for (noun, verb) in NotesComponent.cli.defaultVerbs {
            #expect(NotesComponent.cli.routes.contains { $0.noun == noun && $0.verb == verb }, "\(noun) \(verb)")
        }
    }

    @Test func identity() {
        let product = NotesComponent.product
        #expect([product.command, product.serverName, product.bundleID, product.appName, product.environmentPrefix]
            == ["apple-notes-mcp", "apple-notes", "com.xiaofeng.apple-notes-mcp", "AppleNotesMCP", "APPLE_NOTES_MCP"])
    }
}
