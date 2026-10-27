import Agents
import Foundation
import Wire

/// User settings, in the app's defaults domain (its bundle id), so the settings window, `defaults
/// write` and every MCP client share them. Each app adds its own (Reminders: whether repeating
/// reminders may be completed) in an extension. Not called Settings, which SwiftUI also has.
public enum AppSettings {
    static let interfaceLanguageKey = "InterfaceLanguage"

    /// The settings window's language, "en" or "zh-Hans"; nil follows the system.
    static var interfaceLanguage: String? {
        UserDefaults.standard.string(forKey: interfaceLanguageKey)
    }

    static func setInterfaceLanguage(_ value: String?) {
        if let value {
            UserDefaults.standard.set(value, forKey: interfaceLanguageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: interfaceLanguageKey)
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    /// Which tools AI assistants are offered: tools.json next to the app's other files, chosen in the
    /// settings window's Tools tab. <PREFIX>_TOOLS_FILE puts it elsewhere (for checks).
    public static var exposure: ToolExposure {
        let file = toolsFileOverride.map(URL.init(fileURLWithPath:)) ?? supportDirectory.appendingPathComponent("tools.json")
        return ToolExposure(file: file, changedIn: "the Tools tab of the \(Product.current.name) settings window (opened by opening the app)")
    }

    static var toolsFileVariable: String { Product.current.environmentPrefix + "_TOOLS_FILE" }

    static var toolsFileOverride: String? {
        ProcessInfo.processInfo.environment[toolsFileVariable].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Where the app keeps its own files (Notes: note backups and descriptions; Reminders: what it
    /// deleted), and the choice of tools: ~/Library/Application Support/<appName>.
    public static var supportDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(Product.current.appName)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
