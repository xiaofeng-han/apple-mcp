import Foundation

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

    /// Where the app keeps its own files: note backups and descriptions.
    static var supportDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AppleNotesMCP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
