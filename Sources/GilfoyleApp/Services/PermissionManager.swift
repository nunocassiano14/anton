import AppKit
import Combine
import Foundation

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var automationFailures: [String]?

    var automationRequestAttempted: Bool { automationFailures != nil }
    var automationReady: Bool { automationFailures?.isEmpty == true }

    func requestAutomation(completion: @escaping ([String]) -> Void) {
        var targets: [(String, String)] = []
        if NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) != nil {
            targets.append((
                "Terminal",
                #"tell application "Terminal" to get version"#
            ))
        }
        if NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.googlecode.iterm2"
        ) != nil {
            targets.append((
                "iTerm",
                #"tell application "iTerm2" to get version"#
            ))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            for (name, script) in targets {
                let process = Process()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errors
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        failures.append(name)
                    }
                } catch {
                    failures.append(name)
                }
            }
            DispatchQueue.main.async {
                self.automationFailures = failures
                completion(failures)
            }
        }
    }
}
