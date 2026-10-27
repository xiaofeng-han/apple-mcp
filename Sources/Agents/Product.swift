import Synchronization

/// Which app this is: Apple Notes MCP or Apple Reminders MCP. The shared code reads every name it
/// writes into agents' settings, skills, backups and messages from here, and each app sets it as it
/// starts, before anything else runs. The values are the ones each app always had, so nothing a
/// user or an agent sees changes.
public struct Product: Sendable {
    /// "Apple Notes MCP": the window, menus and messages.
    public let name: String
    /// "com.xiaofeng.apple-notes-mcp": only this bundle relaunches itself to hold its permissions.
    public let bundleID: String
    /// "AppleNotesMCP": the app, its executable and its folder in Application Support.
    public let appName: String
    /// "apple-notes-mcp": the command and cask, serverInfo.name, the skill's marker, backup names.
    public let command: String
    /// "apple-notes": the server's name in agents' settings, and the skill's folder.
    public let serverName: String
    /// "APPLE_NOTES_MCP": the start of the app's environment variables.
    public let environmentPrefix: String
    /// What the server reaches, in English and Chinese ("Notes", "备忘录").
    public let subject: String
    public let chineseSubject: String

    public init(name: String, bundleID: String, appName: String, command: String, serverName: String,
                environmentPrefix: String, subject: String, chineseSubject: String) {
        self.name = name
        self.bundleID = bundleID
        self.appName = appName
        self.command = command
        self.serverName = serverName
        self.environmentPrefix = environmentPrefix
        self.subject = subject
        self.chineseSubject = chineseSubject
    }

    private static let configured = Mutex<Product?>(nil)

    /// This app. Set once as it starts (tests set it in each suite).
    public static var current: Product {
        get {
            guard let product = configured.withLock({ $0 }) else {
                fatalError("Product.current was read before the app set it")
            }
            return product
        }
        set { configured.withLock { $0 = newValue } }
    }
}
