import Darwin
import Foundation

/// Installs a per-user launchd job so Anton keeps running locally after a
/// crash or an unexpected termination. A normal Quit exits with status 0,
/// which `SuccessfulExit = false` deliberately does not relaunch.
enum LocalOverlaySupervisor {
    private static let label = "com.augustalabs.anton.overlay"
    private static let launchAgentEnvironmentKey = "ANTON_LAUNCH_AGENT"

    static var isSupervisedProcess: Bool {
        ProcessInfo.processInfo.environment[launchAgentEnvironmentKey] == "1"
    }

    /// Returns true only when a supervised replacement was successfully
    /// started. The caller should then terminate this manually-opened copy.
    static func relaunchUnderSupervisorIfNeeded() -> Bool {
        guard !isSupervisedProcess,
              let executable = Bundle.main.executableURL
        else { return false }

        do {
            let plistURL = try writeLaunchAgent(executable: executable)
            let domain = "gui/\(getuid())"
            if isLoaded(in: domain) {
                try runLaunchctl(["kickstart", "-k", "\(domain)/\(label)"])
            } else {
                try runLaunchctl(["bootstrap", domain, plistURL.path])
            }
            return true
        } catch {
            // Anton should always remain usable even if launchd registration
            // is unavailable, so this intentionally falls back to the direct
            // process rather than surfacing an intrusive startup error.
            return false
        }
    }

    private static func writeLaunchAgent(executable: URL) throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(label).plist")
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": [launchAgentEnvironmentKey: "1"]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func isLoaded(in domain: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(domain)/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AntonLaunchAgent",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not register Anton with launchd."]
            )
        }
    }
}
