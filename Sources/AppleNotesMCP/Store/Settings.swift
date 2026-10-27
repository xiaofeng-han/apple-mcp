import Foundation
import Wire

/// User settings, in the app's defaults domain (com.xiaofeng.apple-notes-mcp), so the settings
/// window, `defaults write` and every MCP client share them.
enum Settings {
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
    /// settings window's Tools tab. APPLE_NOTES_MCP_TOOLS_FILE puts it elsewhere (for checks).
    static var exposure: ToolExposure {
        let file = toolsFileOverride.map(URL.init(fileURLWithPath:)) ?? supportDirectory.appendingPathComponent("tools.json")
        return ToolExposure(file: file, changedIn: "the Tools tab of the Apple Notes MCP settings window (opened by opening the app)")
    }

    static var toolsFileOverride: String? {
        ProcessInfo.processInfo.environment["APPLE_NOTES_MCP_TOOLS_FILE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Where the app keeps its own files: note backups, descriptions and the choice of tools.
    static var supportDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AppleNotesMCP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
