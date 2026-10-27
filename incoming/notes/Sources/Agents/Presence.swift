import AppKit

/// Whether an agent is on this Mac, and where.
public enum Presence: Sendable, Equatable {
    case absent
    case installed(path: String, version: String?)

    public var path: String? {
        if case .installed(let path, _) = self { return path }
        return nil
    }
}

enum Locator {
    /// The first of `names` found in `folders` or on the PATH a terminal would have. With
    /// `identify`, a candidate's output for those arguments must contain the marker (to skip
    /// unrelated programs with the same name).
    static func command(_ names: [String], folders: [String], identify: (arguments: [String], marker: String)?) -> Presence {
        let manager = FileManager.default
        var candidates = names.flatMap { name in folders.map { "\($0)/\(name)" } }
        candidates += names.compactMap(Shell.which)
        var seen = Set<String>()
        for candidate in candidates where manager.isExecutableFile(atPath: candidate) {
            let real = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard seen.insert(real).inserted else { continue }
            if let identify {
                let output = (try? Shell.runSync(candidate, identify.arguments, environment: Shell.environment, timeout: 15))?.output ?? ""
                guard output.contains(identify.marker) else { continue }
            }
            let output = (try? Shell.runSync(candidate, ["--version"], environment: Shell.environment, timeout: 15))?.output ?? ""
            return .installed(path: candidate, version: version(in: output))
        }
        return .absent
    }

    /// The first app with one of `bundleIDs` in an Applications folder.
    static func app(_ bundleIDs: [String], names: [String], home: URL) -> Presence {
        var candidates = names.flatMap { name in ["/Applications", home.appendingPathComponent("Applications").path].map { "\($0)/\(name).app" } }
            .map { URL(fileURLWithPath: $0) }
        candidates += bundleIDs.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
        for url in candidates {
            let path = url.resolvingSymlinksInPath().path
            // Skip copies in the Trash, on disk images and inside other apps' data.
            guard !path.contains("/.Trash/"), !path.hasPrefix("/Volumes/"), !path.contains("/Library/"),
                let bundle = Bundle(url: url), let id = bundle.bundleIdentifier?.lowercased(), bundleIDs.contains(where: { $0.lowercased() == id })
            else { continue }
            return .installed(path: url.path, version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
        }
        return .absent
    }

    /// The first thing that looks like a version number (1.2.3) in a program's output.
    static func version(in output: String) -> String? {
        output.firstMatch(of: /\d+\.\d+(\.\d+)*([-+.][0-9A-Za-z.]+)?/).map { String($0.output.0) }
    }
}
