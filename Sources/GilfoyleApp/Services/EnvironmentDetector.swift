import AppKit
import Foundation

struct EnvironmentDetection {
    var claudePath: String?
    var codexPath: String?
    var terminalInstalled: Bool
    var iTermInstalled: Bool

    var isReady: Bool {
        claudePath != nil && codexPath != nil && terminalInstalled && iTermInstalled
    }
}
enum EnvironmentDetector {
    static func detect() -> EnvironmentDetection {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return EnvironmentDetection(
            claudePath: firstExisting([
                home.appendingPathComponent(".local/bin/claude").path,
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]),
            codexPath: firstExisting([
                home.appendingPathComponent(".local/bin/codex").path,
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]),
            terminalInstalled: FileManager.default.fileExists(
                atPath: "/System/Applications/Utilities/Terminal.app"
            ),
            iTermInstalled: [
                home.appendingPathComponent("Applications/iTerm.app").path,
                "/Applications/iTerm.app",
                "/Applications/iTerm2.app"
            ].contains(where: FileManager.default.fileExists(atPath:))
        )
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}
