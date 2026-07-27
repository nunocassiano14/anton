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
        let claudeHistory = ResumableSessionParser.claudeHistory(
            boundedTail(
                home.appendingPathComponent(".claude/history.jsonl"),
                maximumBytes: 4_194_304
            )
        )
        let claude = enrichClaudeSessions(
            Array(claudeHistory.prefix(limit))
        )
        let codexDatabase = codexThreads()
        let codexIndex = codexIndex()
        let codex = codexDatabase.isEmpty
            ? codexIndex
            : ResumableSessionParser.mergingMetadata(
                into: codexDatabase,
                from: codexIndex
            )
        return Array(
            ResumableSessionParser
                .deduplicated(claude + codex)
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
              coalesce(nullif(title, ''), '') as title,
              coalesce(nullif(name, ''), '') as explicit_name,
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

    private func enrichClaudeSessions(
        _ sessions: [ResumableAgentSession]
    ) -> [ResumableAgentSession] {
        let transcriptURLs = Dictionary(
            uniqueKeysWithValues: sessions.compactMap { session in
                claudeTranscriptURL(for: session).map { (session.sessionID, $0) }
            }
        )
        let customTitles = claudeCustomTitles(
            in: Array(transcriptURLs.values)
        )
        let liveNames = claudeLiveNames()

        return sessions.compactMap { session in
            // Claude's history can outlive the transcript required by
            // `--resume`. Do not offer entries that can no longer start.
            guard let transcriptURL = transcriptURLs[session.sessionID] else {
                return nil
            }
            let transcript = boundedTail(
                transcriptURL,
                maximumBytes: 262_144
            )
            let transcriptMetadata = ResumableSessionParser
                .claudeTranscriptMetadata(transcript)
            return session.enriching(
                explicitName: customTitles[session.sessionID]
                    ?? transcriptMetadata.explicitName
                    ?? liveNames[session.sessionID],
                gitBranch: transcriptMetadata.gitBranch
            )
        }
    }

    private func claudeTranscriptURL(
        for session: ResumableAgentSession
    ) -> URL? {
        guard !session.cwd.isEmpty else { return nil }
        let projectFolder = session.cwd.replacingOccurrences(of: "/", with: "-")
        let url = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(projectFolder, isDirectory: true)
            .appendingPathComponent("\(session.sessionID).jsonl")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Claude does not maintain a global title index. Scan only the known
    /// transcript files and return their tiny `custom-title` records.
    private func claudeCustomTitles(in transcriptURLs: [URL]) -> [String: String] {
        guard !transcriptURLs.isEmpty else { return [:] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = [
            "-h",
            #""type":"custom-title""#,
            "--"
        ] + transcriptURLs.map(\.path)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ResumableSessionParser.claudeCustomTitles(data)
        } catch {
            return [:]
        }
    }

    private func claudeLiveNames() -> [String: String] {
        struct LiveSession: Decodable {
            let sessionId: String?
            let name: String?
        }

        let directory = home.appendingPathComponent(".claude/sessions")
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return [:]
        }
        var names: [String: String] = [:]
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let live = try? JSONDecoder().decode(LiveSession.self, from: data),
                let sessionID = normalized(live.sessionId),
                let name = normalized(live.name)
            else {
                continue
            }
            names[sessionID] = name
        }
        return names
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
