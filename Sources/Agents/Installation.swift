import Foundation

/// How this copy of the app (`Product.current`) was installed, and so which command agents should start.
public struct Installation: Sendable, Equatable {
    public enum Method: Sendable, Equatable {
        /// `brew install --cask`, with Homebrew's prefix (/opt/homebrew).
        case homebrew(prefix: String)
        /// The release package, installed for all users (/Applications) or for one (~/Applications).
        case package(allUsers: Bool)
        /// Built from source, copied by hand, or run outside the app bundle.
        case other
    }

    public static var bundleID: String { Product.current.bundleID }
    public static var packageID: String { Product.current.bundleID + ".pkg" }
    public static var caskName: String { Product.current.command }

    public let method: Method
    /// The app bundle, or nil for a bare executable (swift run).
    public let bundle: URL?
    /// What agents should start, with `--stdio`: Homebrew's script (`apple-notes-mcp`, say), whose
    /// path survives upgrades, or else the app's executable.
    public let command: String

    public var arguments: [String] { ["--stdio"] }

    /// Homebrew's prefix, when this copy came from Homebrew.
    public var homebrewPrefix: String? {
        if case .homebrew(let prefix) = method { return prefix }
        return nil
    }

    public init(method: Method, bundle: URL?, command: String) {
        self.method = method
        self.bundle = bundle
        self.command = command
    }

    /// Looks at where the running app is and what installed it.
    public static func detect(bundle: Bundle = .main, home: URL = Shell.home) -> Installation {
        let manager = FileManager.default
        let executable = (bundle.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        guard bundle.bundleIdentifier == bundleID else { return Installation(method: .other, bundle: nil, command: executable) }
        let app = bundle.bundleURL.resolvingSymlinksInPath()
        let systemApp = "/Applications/\(Product.current.appName).app"
        if app.path == systemApp {
            for prefix in ["/opt/homebrew", "/usr/local"] where manager.fileExists(atPath: "\(prefix)/Caskroom/\(caskName)") {
                let wrapper = "\(prefix)/bin/\(caskName)"
                return Installation(method: .homebrew(prefix: prefix), bundle: app,
                                    command: manager.isExecutableFile(atPath: wrapper) ? wrapper : executable)
            }
            if hasReceipt(volume: "/") { return Installation(method: .package(allUsers: true), bundle: app, command: executable) }
        } else if app.path == home.appendingPathComponent("Applications/\(Product.current.appName).app").path, hasReceipt(volume: home.path) {
            return Installation(method: .package(allUsers: false), bundle: app, command: executable)
        }
        return Installation(method: .other, bundle: app, command: executable)
    }

    /// Whether the installer recorded the release package on `volume` ("/" for all users, the home
    /// folder for one user).
    static func hasReceipt(volume: String) -> Bool {
        let result = try? Shell.runSync("/usr/sbin/pkgutil", ["--volume", volume, "--pkg-info", packageID],
                                        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 10)
        return result?.succeeded == true
    }
}
