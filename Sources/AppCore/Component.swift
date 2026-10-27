import Agents
import SwiftUI
import Wire

/// What AppMain hands an app as it starts.
public struct ComponentContext: Sendable {
    /// CFBundleShortVersionString, or "dev" for a bare build.
    public let version: String
    /// <PREFIX>_WRITE_GUARD, unless unset or empty: while it is set (development and checks), writes
    /// are limited to what it names. Each app reads it its own way.
    public let writeGuard: String?

    public init(version: String, writeGuard: String?) {
        self.version = version
        self.writeGuard = writeGuard
    }
}

/// One app on the shared base: Apple Notes MCP or Apple Reminders MCP. The base (AppMain) serves
/// MCP, runs the commands, `agents`, `skill`, `--self-check` and `--version`, and opens the
/// settings window; the app gives its tools and everything about them that differs. Its
/// executable is `AppMain.run(NotesComponent.self)`.
@MainActor
public protocol Component: AnyObject, Sendable {
    /// Which app this is. AppMain sets Product.current to it before anything else runs.
    nonisolated static var product: Product { get }
    /// The commands: routes, default verbs and the app's own wording.
    nonisolated static var cli: CLI { get }
    /// The tools' titles in Chinese, for the Tools tab; the English ones are what agents see.
    nonisolated static var chineseToolTitles: [String: String] { get }
    /// The skill's description and the text before its command reference, for the command `run`.
    nonisolated static func skill(run: String) -> SkillText

    /// Makes the store and the tools.
    init(_ context: ComponentContext)
    /// What the server offers and the commands run.
    var tools: [Tool] { get }
    /// MCP initialize's instructions.
    var instructions: String { get }
    /// Words this app alone takes as its first, besides the shared ones (which come first), and
    /// what each runs with all the words: Notes' --copy-note and --check-markdown, Reminders'
    /// authorize (setup).
    var modes: [String: @MainActor @Sendable ([String]) async -> Int32] { get }
    /// `setup`: checks the app's permissions from a terminal, and asks for them; the exit status.
    func setup() async -> Int32
    /// What `--self-check` prints after its first line and before the tools: permissions and data.
    func selfCheck() async -> [String]
    /// How `--self-check` shows the write guard, when one is set.
    var writeGuardDescription: String? { get }
    /// The General tab above the language: what the app may access, and its settings.
    func generalSection(_ panel: PanelState) -> AnyView
}

extension Component {
    /// The skill for a copy of the app (`agents`, `skill`, the AI Assistants tab), on any thread.
    var skillText: @Sendable (Installation) -> String {
        let tools = self.tools
        return { installation in Skill.text(for: installation, cli: Self.cli, tools: tools, text: Self.skill(run:)) }
    }
}
