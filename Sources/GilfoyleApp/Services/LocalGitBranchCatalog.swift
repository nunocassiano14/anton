import Foundation
import GilfoyleCore

struct WorkspaceGitBranches: Equatable, Sendable {
    let workspace: String
    let repositoryRoot: String?
    let currentBranch: String?
    let localBranches: [String]

    static func empty(workspace: String) -> WorkspaceGitBranches {
        WorkspaceGitBranches(
            workspace: workspace,
            repositoryRoot: nil,
            currentBranch: nil,
            localBranches: []
        )
    }
}

struct AgentBranchReference: Identifiable, Equatable, Sendable {
    var id: String { "\(workspace)\u{0}\(name)" }
    let name: String
    let workspace: String
    let agent: AgentKind
    let updatedAt: Date
}

final class LocalGitBranchCatalog: @unchecked Sendable {
    func load(workspace: String) -> WorkspaceGitBranches {
        let normalizedWorkspace = workspace
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspace.isEmpty,
              FileManager.default.fileExists(atPath: normalizedWorkspace),
              let root = gitOutput(
                  arguments: [
                      "-C", normalizedWorkspace,
                      "rev-parse", "--show-toplevel"
                  ]
              )
        else {
            return .empty(workspace: normalizedWorkspace)
        }

        let currentBranch = gitOutput(
            arguments: [
                "-C", normalizedWorkspace,
                "branch", "--show-current"
            ]
        )
        let branches = gitOutput(
            arguments: [
                "-C", normalizedWorkspace,
                "for-each-ref",
                "--sort=-committerdate",
                "--format=%(refname:short)",
                "refs/heads"
            ]
        )?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        var seen = Set<String>()
        let ordered = ([currentBranch].compactMap { $0 } + branches)
            .filter { seen.insert($0).inserted }

        return WorkspaceGitBranches(
            workspace: normalizedWorkspace,
            repositoryRoot: root,
            currentBranch: currentBranch,
            localBranches: ordered
        )
    }

    private func gitOutput(arguments: [String]) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
