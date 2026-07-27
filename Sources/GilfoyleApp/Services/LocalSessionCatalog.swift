import Foundation
import GilfoyleCore

final class LocalSessionCatalog: @unchecked Sendable {
    private let home: URL
    private let fileManager: FileManager

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.fileManager = fileManager
    }

    func load(limit: Int = 300) -> [ResumableAgentSession] {
        let claude = ResumableSessionParser.claudeHistory(
            boundedTail(
                home.appendingPathComponent(".claude/history.jsonl"),
                maximumBytes: 4_194_304
            )
        )
        let codex = codexThreads()
        let fallback = codex.isEmpty ? codexIndex() : []
        return Array(
            ResumableSessionParser
                .deduplicated(claude + codex + fallback)
                .prefix(limit)
        )
    }

    private func codexThreads() -> [ResumableAgentSession] {
        let database = home.appendingPathComponent(".codex/state_5.sqlite")
        guard fileManager.fileExists(atPath: database.path) else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json",
            database.path,
            """
            select
              id,
              cwd,
              coalesce(nullif(name, ''), nullif(title, ''), nullif(agent_nickname, ''), '') as title,
              coalesce(updated_at_ms, updated_at * 1000, created_at_ms, created_at * 1000, 0) as updated_at_ms,
              coalesce(model, '') as model,
              coalesce(preview, '') as preview,
              coalesce(git_branch, '') as git_branch,
              coalesce(archived, 0) as archived
            from threads
            where coalesce(archived, 0) = 0
            order by coalesce(updated_at_ms, updated_at * 1000, created_at_ms, created_at * 1000, 0) desc
            limit 500;
            """
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return ResumableSessionParser.codexThreads(data)
        } catch {
            return []
        }
    }

    private func codexIndex() -> [ResumableAgentSession] {
        ResumableSessionParser.codexIndex(
            boundedTail(
                home.appendingPathComponent(".codex/session_index.jsonl"),
                maximumBytes: 2_097_152
            )
        )
    }

    private func boundedTail(_ url: URL, maximumBytes: UInt64) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        let offset = length > maximumBytes ? length - maximumBytes : 0
        try? handle.seek(toOffset: offset)
        var data = handle.readDataToEndOfFile()
        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        return data
    }
}
