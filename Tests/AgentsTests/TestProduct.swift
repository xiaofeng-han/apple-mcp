@testable import Agents

/// The app the Agents tests stand in for. The expectations spell out its names (apple-reminders,
/// apple-reminders-mcp), so each suite sets it as it starts; Swift Testing makes a new suite
/// instance, and so runs its init, for every test.
extension Product {
    static let testing = Product(name: "Apple Reminders MCP", bundleID: "com.xiaofeng.apple-reminders-mcp",
                                 appName: "AppleRemindersMCP", command: "apple-reminders-mcp", serverName: "apple-reminders",
                                 environmentPrefix: "APPLE_REMINDERS_MCP", subject: "Reminders", chineseSubject: "提醒事项")
}
