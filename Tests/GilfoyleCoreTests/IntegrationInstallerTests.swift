import Foundation
import Testing
@testable import GilfoyleCore

@Suite("Integration installer", .serialized)
struct IntegrationInstallerTests {
    @Test("Claude install and removal preserve unrelated settings and hooks")
    func claudeInstallPreservesExistingSettingsAndUninstallPreservesOtherHooks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let url = fixture.installer.claudeSettingsURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "model": "claude-test",
            "theme": "dark",
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "/usr/local/bin/company-policy"
                            ]
                        ]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: url)

        let change = try fixture.installer.installClaude()
        #expect(change.changed)
        #expect(change.backupURL != nil)
        #expect(fixture.installer.status(for: .claude).state == .installed)

        var installed = try load(url)
        #expect(installed["model"] as? String == "claude-test")
        #expect(installed["theme"] as? String == "dark")
        #expect(serialized(installed).contains("company-policy"))
        #expect(serialized(installed).contains("anton-hook"))

        let duplicateInstall = try fixture.installer.installClaude()
        #expect(!duplicateInstall.changed)

        let relocated = IntegrationInstaller(
            homeURL: fixture.home,
            helperURL: URL(fileURLWithPath: "/Users/test/Applications/Anton.app/Contents/Helpers/anton-hook"),
            backupsURL: fixture.home.appendingPathComponent("Backups")
        )
        #expect(relocated.status(for: .claude).state == .incomplete)
        let repair = try relocated.installClaude()
        #expect(repair.changed)
        installed = try load(url)
        let repairedText = serialized(installed)
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(repairedText.contains("/Users/test/Applications/Anton.app"))
        #expect(!repairedText.contains("'/Applications/Anton.app"))
        let repeatedRepair = try relocated.installClaude()
        #expect(!repeatedRepair.changed)

        let removal = try relocated.removeClaude()
        #expect(removal.changed)
        installed = try load(url)
        #expect(installed["model"] as? String == "claude-test")
        #expect(serialized(installed).contains("company-policy"))
        #expect(!serialized(installed).contains("anton-hook"))
    }

    @Test("Codex hooks file is created and removed cleanly")
    func codexHooksFileIsCreatedAndRemovedCleanly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        #expect(!FileManager.default.fileExists(atPath: fixture.installer.codexHooksURL.path))
        _ = try fixture.installer.installCodex()
        #expect(fixture.installer.status(for: .codex).state == .installed)
        #expect(FileManager.default.fileExists(atPath: fixture.installer.codexHooksURL.path))
        #expect(
            try load(fixture.installer.codexHooksURL)["description"] as? String
                == "Anton local lifecycle integration. Remove through Anton Settings."
        )

        _ = try fixture.installer.removeCodex()
        #expect(!FileManager.default.fileExists(atPath: fixture.installer.codexHooksURL.path))
    }

    @Test("Anton repairs a legacy Gilfoyle hook without touching other handlers")
    func legacyHookIsMigrated() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let url = fixture.installer.claudeSettingsURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "hooks": [
                        ["type": "command", "command": "'/Applications/Gilfoyle.app/Contents/Helpers/gilfoyle-hook' --agent claude"],
                        ["type": "command", "command": "/usr/local/bin/team-audit"]
                    ]
                ]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        #expect(fixture.installer.status(for: .claude).state == .incomplete)
        #expect(try fixture.installer.installClaude().changed)
        let text = serialized(try load(url))
        #expect(text.contains("anton-hook"))
        #expect(!text.contains("gilfoyle-hook"))
        #expect(text.contains("team-audit"))
    }

    private func makeFixture() throws -> (home: URL, installer: IntegrationInstaller) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("anton-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (
            home,
            IntegrationInstaller(
                homeURL: home,
                helperURL: URL(fileURLWithPath: "/Applications/Anton.app/Contents/Helpers/anton-hook"),
                backupsURL: home.appendingPathComponent("Backups")
            )
        )
    }

    private func load(_ url: URL) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func serialized(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
