import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var automationRequestAttempted = false

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func requestAutomation(completion: @escaping ([String]) -> Void) {
        let targets: [(String, String)] = [
            (
                "Terminal",
                #"tell application "Terminal" to get version"#
            ),
            (
                "iTerm",
                #"tell application "iTerm2" to get version"#
            )
        ]

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
                self.automationRequestAttempted = true
                completion(failures)
            }
        }
    }
}
