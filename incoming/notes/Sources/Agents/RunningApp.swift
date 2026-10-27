import AppKit

/// Agents' apps that are open right now.
public enum RunningApp {
    public static func instances(of bundleIDs: [String]) -> [NSRunningApplication] {
        bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.filter { !$0.isTerminated }
    }

    public static func isRunning(_ bundleIDs: [String]) -> Bool { !instances(of: bundleIDs).isEmpty }

    /// Asks the app to quit, as Quit in its menu would, and waits for it. Returns where it was, to
    /// open it again; throws if it is still running after `timeout` (it may be asking the user
    /// something).
    public static func quit(_ bundleIDs: [String], name: String, timeout: TimeInterval = 30) async throws -> URL? {
        let running = instances(of: bundleIDs)
        let location = running.first?.bundleURL
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning(bundleIDs) {
            guard Date() < deadline else { throw ConfigError("\(name) did not quit") }
            try await Task.sleep(for: .milliseconds(250))
        }
        return location
    }

    public static func open(_ url: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
