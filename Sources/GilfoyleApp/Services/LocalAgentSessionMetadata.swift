import Foundation
import GilfoyleCore

/// Reads bounded local session metadata needed for labels, lifecycle state,
/// and the latest response preview. The data remains on-device; prompts and
/// transcript paths are never forwarded through Anton's bridge.
struct LocalAgentSessionMetadata {
    var agentSessionID: String?
    var name: String?
    var model: String?
    var cwd: String?
    var lastResponsePreview: String?
    var state: AgentSessionState = .idle
    var taskTurnID: String?
    var taskStartedAt: Date?
    var activity: String?

    private struct CachedCodexSession {
        let value: (id: String, rolloutURL: URL)?
        let storedAt: Date
    }

    private struct CachedCodexDetails {
        let value: (name: String?, model: String?)
        let storedAt: Date
    }

    private static let cacheLock = NSLock()
    private static var codexSessionCache: [Int32: CachedCodexSession] = [:]
    private static var codexDetailsCache: [String: CachedCodexDetails] = [:]

    static func pruneCaches(liveProcessIDs: Set<Int32>) {
        cacheLock.lock()
        codexSessionCache = codexSessionCache.filter {
            liveProcessIDs.contains($0.key)
        }
        let cutoff = Date().addingTimeInterval(-300)
        codexDetailsCache = codexDetailsCache.filter {
            $0.value.storedAt >= cutoff
        }
        cacheLock.unlock()
    }

    static func read(agent: AgentKind, processID: Int32) -> LocalAgentSessionMetadata {
        if agent == .codex, let session = cachedCodexSession(openBy: processID) {
            let details = cachedCodexDetails(sessionID: session.id)
            let rollout = rolloutData(session.rolloutURL)
            let lifecycle = CodexRolloutLifecycle.snapshot(in: rollout)
            return LocalAgentSessionMetadata(
                agentSessionID: session.id,
                name: details.name,
                model: details.model,
                lastResponsePreview: LocalAgentResponsePreview.codex(in: rollout),
                state: lifecycle.state,
                taskTurnID: lifecycle.turnID,
                taskStartedAt: lifecycle.taskStartedAt,
                activity: lifecycle.activity
            )
        }
        guard agent == .claude else { return LocalAgentSessionMetadata() }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(processID).json")
        guard let data = try? Data(contentsOf: url),
              let live = try? JSONDecoder().decode(ClaudeLiveSession.self, from: data)
        else {
            return LocalAgentSessionMetadata()
        }
        let transcript = claudeTranscriptData(sessionID: live.sessionID)
        let lifecycle = ClaudeTranscriptLifecycle.snapshot(in: transcript)
        let state: AgentSessionState
        if live.status.lowercased() == "busy" {
            state = .working
        } else if lifecycle.hasCompletedLatestTurn {
            state = .finished
        } else if lifecycle.lastUserAt != nil {
            state = .working
        } else {
            state = .idle
        }
        return LocalAgentSessionMetadata(
            agentSessionID: live.sessionID,
            name: live.name,
            model: modelFromClaudeLog(sessionID: live.sessionID),
            cwd: live.cwd,
            lastResponsePreview: LocalAgentResponsePreview.claude(in: transcript),
            state: state,
            taskTurnID: lifecycle.lastUserTurnID,
            taskStartedAt: lifecycle.lastUserAt,
            activity: state == .working ? "Thinking" : nil
        )
    }

    static func titleAndModel(agent: AgentKind, sessionID: String) -> (name: String?, model: String?) {
        switch agent {
        case .codex:
            let live = codexLiveThread(sessionID: sessionID)
            return (
                codexThreadName(sessionID: sessionID) ?? live.name,
                live.model ?? modelFromCodexLog(sessionID: sessionID)
            )
        case .claude:
            return (nil, nil)
        }
    }

    private static func codexThreadName(sessionID: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? JSONDecoder().decode(CodexIndexEntry.self, from: data),
                  entry.id == sessionID
            else { continue }
            return entry.threadName
        }
        return nil
    }

    /// `state_5.sqlite` is Codex's live thread registry. Unlike a rollout it
    /// records the currently selected model, not every model used earlier in
    /// the conversation.
    private static func codexLiveThread(sessionID: String) -> (name: String?, model: String?) {
        guard sessionID.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil else {
            return (nil, nil)
        }
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-separator", "\t", database,
            "select coalesce(name, ''), coalesce(model, '') from threads where id = '\(sessionID)' limit 1;"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // Preserve the leading tab: it represents an empty `name` column
            // followed by a valid model value.
            guard let row = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .newlines), !row.isEmpty
            else { return (nil, nil) }
            let values = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let name = values.indices.contains(0) ? String(values[0]).nonEmpty : nil
            let model = values.indices.contains(1) ? String(values[1]).nonEmpty : nil
            return (name, model)
        } catch {
            return (nil, nil)
        }
    }

    /// Codex keeps the active rollout JSONL open for the lifetime of the
    /// process. `lsof` gives us the exact PID → thread association, including
    /// sessions that were already open when Anton launched.
    private static func cachedCodexSession(
        openBy processID: Int32
    ) -> (id: String, rolloutURL: URL)? {
        cacheLock.lock()
        if let cached = codexSessionCache[processID] {
            let lifetime: TimeInterval = cached.value == nil ? 5 : 60
            guard Date().timeIntervalSince(cached.storedAt) < lifetime else {
                cacheLock.unlock()
                return refreshCodexSessionCache(processID: processID)
            }
            cacheLock.unlock()
            return cached.value
        }
        cacheLock.unlock()

        return refreshCodexSessionCache(processID: processID)
    }

    private static func refreshCodexSessionCache(
        processID: Int32
    ) -> (id: String, rolloutURL: URL)? {
        let value = locateCodexSession(openBy: processID)
        cacheLock.lock()
        codexSessionCache[processID] = CachedCodexSession(
            value: value,
            storedAt: Date()
        )
        cacheLock.unlock()
        return value
    }

    private static func cachedCodexDetails(
        sessionID: String
    ) -> (name: String?, model: String?) {
        cacheLock.lock()
        if let cached = codexDetailsCache[sessionID],
           Date().timeIntervalSince(cached.storedAt) < 30 {
            cacheLock.unlock()
            return cached.value
        }
        cacheLock.unlock()

        let value = titleAndModel(agent: .codex, sessionID: sessionID)
        cacheLock.lock()
        codexDetailsCache[sessionID] = CachedCodexDetails(
            value: value,
            storedAt: Date()
        )
        cacheLock.unlock()
        return value
    }

    private static func locateCodexSession(
        openBy processID: Int32
    ) -> (id: String, rolloutURL: URL)? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", String(processID), "-Fn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
                let path = String(line.dropFirst())
                guard path.contains("/.codex/sessions/"), path.hasSuffix(".jsonl") else { continue }
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                if let range = name.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression) {
                    return (String(name[range]), URL(fileURLWithPath: path))
                }
            }
        } catch {}
        return nil
    }

    /// Codex stores lifecycle events in the local rollout. Its modification
    /// time is not a state signal: a completed turn may keep receiving log
    /// writes, and a quiet working turn may write nothing for a while. Read a
    /// bounded tail and use the most recent task boundary instead.
    private static func rolloutData(_ url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: length > 524_288 ? length - 524_288 : 0)
        return handle.readDataToEndOfFile()
    }

    private static func modelFromClaudeLog(sessionID: String) -> String? {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let configuredModel = (try? Data(contentsOf: settingsURL))
            .flatMap { AgentModelMetadata.configuredClaudeModel(in: $0) }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let url = firstFile(named: "\(sessionID).jsonl", below: root) else { return configuredModel }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: length > 262_144 ? length - 262_144 : 0)
        let tail = handle.readDataToEndOfFile()
        return AgentModelMetadata.latestClaudeModelChange(in: tail)
            ?? configuredModel
            ?? model(in: tail)
            ?? lastModel(in: url)
    }

    private static func claudeTranscriptData(sessionID: String) -> Data {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let url = firstFile(named: "\(sessionID).jsonl", below: root),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return Data() }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: length > 524_288 ? length - 524_288 : 0)
        return handle.readDataToEndOfFile()
    }

    private static func modelFromCodexLog(sessionID: String) -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let url = firstFile(namedSuffix: "-\(sessionID).jsonl", below: root) else { return nil }
        return lastModel(in: url)
    }

    private static func firstFile(named name: String, below root: URL) -> URL? {
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: options)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == name }
    }

    private static func firstFile(namedSuffix suffix: String, below root: URL) -> URL? {
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: options)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent.hasSuffix(suffix) }
    }

    private static func lastModel(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        // Codex writes model configuration in the rollout header, while some
        // agents repeat it near the tail. Inspect both bounded regions rather
        // than loading a potentially very large transcript.
        try? handle.seek(toOffset: 0)
        let head = handle.readData(ofLength: 262_144)
        try? handle.seek(toOffset: length > 262_144 ? length - 262_144 : 0)
        let tail = handle.readDataToEndOfFile()
        return model(in: tail) ?? model(in: head)
    }

    private static func model(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"\"model\"\s*:\s*\"([^\"]+)\""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.last, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

private struct ClaudeLiveSession: Decodable {
    let sessionID: String
    let cwd: String
    let name: String?
    let status: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cwd, name, status
    }
}

private struct CodexIndexEntry: Decodable {
    let id: String
    let threadName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
