import Foundation

public enum AgentSessionLaunchMode: String, Codable, CaseIterable, Sendable {
    case new
    case resume
    case fork
}

public struct ResumableAgentSession: Identifiable, Equatable, Sendable {
    public var id: String { "\(agent.rawValue):\(sessionID)" }
    public let agent: AgentKind
    public let sessionID: String
    /// A name explicitly assigned by the user through `/rename` or `--name`.
    public let explicitName: String?
    /// Agent-owned fallback text. This can originate from a first prompt and
    /// must not be used as the visible session name.
    public let title: String
    public let cwd: String
    public let updatedAt: Date
    public let model: String?
    public let preview: String?
    public let gitBranch: String?
    public let isArchived: Bool
    public var isRunning: Bool

    public init(
        agent: AgentKind,
        sessionID: String,
        title: String,
        explicitName: String? = nil,
        cwd: String,
        updatedAt: Date,
        model: String? = nil,
        preview: String? = nil,
        gitBranch: String? = nil,
        isArchived: Bool = false,
        isRunning: Bool = false
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.explicitName = Self.normalized(explicitName)
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.model = model
        self.preview = preview
        self.gitBranch = gitBranch
        self.isArchived = isArchived
        self.isRunning = isRunning
    }

    /// The Resume browser deliberately never promotes prompt text to a title.
    /// A user-supplied name wins, then the historical Git branch, followed by
    /// an honest workspace label when neither piece of metadata exists.
    public var displayTitle: String {
        if let explicitName {
            return explicitName
        }
        if let gitBranch = Self.normalizedBranch(gitBranch) {
            return gitBranch
        }
        let workspace = URL(fileURLWithPath: cwd).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !workspace.isEmpty && workspace != "/" {
            return "\(agent.displayName) · \(workspace)"
        }
        return "\(agent.displayName) session"
    }

    public func enriching(
        explicitName: String? = nil,
        gitBranch: String? = nil
    ) -> ResumableAgentSession {
        ResumableAgentSession(
            agent: agent,
            sessionID: sessionID,
            title: title,
            explicitName: explicitName ?? self.explicitName,
            cwd: cwd,
            updatedAt: updatedAt,
            model: model,
            preview: preview,
            gitBranch: Self.normalizedBranch(gitBranch) ?? self.gitBranch,
            isArchived: isArchived,
            isRunning: isRunning
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(96))
    }

    private static func normalizedBranch(_ value: String?) -> String? {
        guard let branch = normalized(value), branch != "HEAD" else { return nil }
        return branch
    }
}

public struct ResumableSessionMetadata: Equatable, Sendable {
    public let explicitName: String?
    public let gitBranch: String?

    public init(explicitName: String? = nil, gitBranch: String? = nil) {
        self.explicitName = explicitName
        self.gitBranch = gitBranch
    }
}

public struct AgentSessionLaunchPlan: Equatable, Sendable {
    public let launchToken: String
    public let agent: AgentKind
    public let mode: AgentSessionLaunchMode
    public let executablePath: String
    public let cwd: String
    public let priorSessionID: String?
    public let sessionName: String?
    public let gitBranch: String?
    public let terminalKind: TerminalKind

    public init(
        launchToken: String,
        agent: AgentKind,
        mode: AgentSessionLaunchMode,
        executablePath: String,
        cwd: String,
        priorSessionID: String? = nil,
        sessionName: String? = nil,
        gitBranch: String? = nil,
        terminalKind: TerminalKind
    ) {
        self.launchToken = launchToken
        self.agent = agent
        self.mode = mode
        self.executablePath = executablePath
        self.cwd = cwd
        self.priorSessionID = priorSessionID
        self.sessionName = sessionName
        self.gitBranch = gitBranch
        self.terminalKind = terminalKind
    }
}

public enum AgentSessionLaunchError: LocalizedError, Equatable {
    case missingExecutable
    case missingWorkspace
    case missingPriorSession
    case unsupportedTerminal

    public var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "The selected agent executable could not be found."
        case .missingWorkspace:
            return "The selected workspace does not exist."
        case .missingPriorSession:
            return "Resume and fork require a saved session ID."
        case .unsupportedTerminal:
            return "The selected terminal is not supported."
        }
    }
}

public enum AgentLaunchCommandBuilder {
    /// Builds one safely quoted shell command for Terminal/iTerm. The initial
    /// user prompt is intentionally absent: Anton delivers it only after the
    /// official SessionStart hook acknowledges the new process.
    public static func command(for plan: AgentSessionLaunchPlan) throws -> String {
        guard !plan.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentSessionLaunchError.missingExecutable
        }
        guard plan.cwd.hasPrefix("/") else {
            throw AgentSessionLaunchError.missingWorkspace
        }
        if plan.mode != .new,
           plan.priorSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            throw AgentSessionLaunchError.missingPriorSession
        }

        var arguments = [
            "/usr/bin/env",
            "ANTON_LAUNCH_TOKEN=\(plan.launchToken)",
            plan.executablePath
        ]
        switch (plan.agent, plan.mode) {
        case (.claude, .new):
            if let name = normalized(plan.sessionName) {
                arguments += ["--name", name]
            }
        case (.claude, .resume):
            arguments += ["--resume", plan.priorSessionID ?? ""]
        case (.claude, .fork):
            arguments += ["--resume", plan.priorSessionID ?? "", "--fork-session"]
        case (.codex, .new):
            break
        case (.codex, .resume):
            arguments += ["resume", plan.priorSessionID ?? ""]
        case (.codex, .fork):
            arguments += ["fork", plan.priorSessionID ?? ""]
        }

        let switchBranch: String
        if plan.mode == .new, let branch = normalized(plan.gitBranch) {
            switchBranch = "/usr/bin/git switch -- \(quote(branch)) && "
        } else {
            switchBranch = ""
        }

        return "cd -- \(quote(plan.cwd)) && "
            + switchBranch
            + "exec "
            + arguments.map(quote).joined(separator: " ")
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum ResumableSessionParser {
    private struct ClaudeHistoryRow: Decodable {
        let display: String?
        let timestamp: Double?
        let project: String?
        let sessionId: String?
    }

    private struct ClaudeTranscriptRow: Decodable {
        let type: String?
        let sessionId: String?
        let customTitle: String?
        let gitBranch: String?
    }

    private struct CodexThreadRow: Decodable {
        let id: String?
        let cwd: String?
        let title: String?
        let explicitName: String?
        let updatedAtMS: Double?
        let model: String?
        let preview: String?
        let gitBranch: String?
        let archived: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case cwd
            case title
            case explicitName = "explicit_name"
            case updatedAtMS = "updated_at_ms"
            case model
            case preview
            case gitBranch = "git_branch"
            case archived
        }
    }

    private struct CodexIndexRow: Decodable {
        let id: String?
        let threadName: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
            case updatedAt = "updated_at"
        }
    }

    public static func claudeHistory(_ data: Data) -> [ResumableAgentSession] {
        var latest: [String: ResumableAgentSession] = [:]
        for line in lines(in: data) {
            guard
                let row = try? JSONDecoder().decode(ClaudeHistoryRow.self, from: line),
                let sessionID = normalized(row.sessionId),
                let cwd = normalized(row.project),
                let timestamp = row.timestamp,
                timestamp > 0
            else {
                continue
            }
            let display = normalized(row.display)
            let candidate = ResumableAgentSession(
                agent: .claude,
                sessionID: sessionID,
                title: boundedTitle(display) ?? "Claude session",
                cwd: cwd,
                updatedAt: Date(timeIntervalSince1970: timestamp / 1_000),
                preview: boundedPreview(display)
            )
            if latest[sessionID]?.updatedAt ?? .distantPast < candidate.updatedAt {
                latest[sessionID] = candidate
            }
        }
        return latest.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func codexThreads(_ data: Data) -> [ResumableAgentSession] {
        guard let rows = try? JSONDecoder().decode([CodexThreadRow].self, from: data) else {
            return []
        }
        return rows.compactMap { row in
            guard
                let sessionID = normalized(row.id),
                let cwd = normalized(row.cwd),
                let updatedAtMS = row.updatedAtMS,
                updatedAtMS > 0
            else {
                return nil
            }
            let preview = normalized(row.preview)
            return ResumableAgentSession(
                agent: .codex,
                sessionID: sessionID,
                title: boundedTitle(normalized(row.title))
                    ?? boundedTitle(preview)
                    ?? "Codex session",
                explicitName: boundedTitle(normalized(row.explicitName)),
                cwd: cwd,
                updatedAt: Date(timeIntervalSince1970: updatedAtMS / 1_000),
                model: normalized(row.model),
                preview: boundedPreview(preview),
                gitBranch: normalizedBranch(row.gitBranch),
                isArchived: row.archived == 1
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func codexIndex(_ data: Data) -> [ResumableAgentSession] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return lines(in: data).compactMap { line in
            guard
                let row = try? JSONDecoder().decode(CodexIndexRow.self, from: line),
                let sessionID = normalized(row.id),
                let updated = normalized(row.updatedAt),
                let date = formatter.date(from: updated)
                    ?? ISO8601DateFormatter().date(from: updated)
            else {
                return nil
            }
            return ResumableAgentSession(
                agent: .codex,
                sessionID: sessionID,
                title: "Codex session",
                explicitName: boundedTitle(normalized(row.threadName)),
                cwd: "",
                updatedAt: date
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func claudeTranscriptMetadata(
        _ data: Data
    ) -> ResumableSessionMetadata {
        var explicitName: String?
        var gitBranch: String?
        for line in lines(in: data) {
            guard let row = try? JSONDecoder().decode(
                ClaudeTranscriptRow.self,
                from: line
            ) else {
                continue
            }
            if row.type == "custom-title",
               let customTitle = boundedTitle(normalized(row.customTitle))
            {
                explicitName = customTitle
            }
            if let branch = normalizedBranch(row.gitBranch) {
                gitBranch = branch
            }
        }
        return ResumableSessionMetadata(
            explicitName: explicitName,
            gitBranch: gitBranch
        )
    }

    public static func claudeCustomTitles(_ data: Data) -> [String: String] {
        var titles: [String: String] = [:]
        for line in lines(in: data) {
            guard
                let row = try? JSONDecoder().decode(ClaudeTranscriptRow.self, from: line),
                row.type == "custom-title",
                let sessionID = normalized(row.sessionId),
                let title = boundedTitle(normalized(row.customTitle))
            else {
                continue
            }
            titles[sessionID] = title
        }
        return titles
    }

    public static func mergingMetadata(
        into primary: [ResumableAgentSession],
        from metadata: [ResumableAgentSession]
    ) -> [ResumableAgentSession] {
        let metadataByID = Dictionary(
            metadata.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.updatedAt > current.updatedAt ? candidate : current
            }
        )
        let primaryIDs = Set(primary.map(\.id))
        let enriched = primary.map { session in
            guard let overlay = metadataByID[session.id] else { return session }
            return session.enriching(
                explicitName: overlay.explicitName,
                gitBranch: overlay.gitBranch
            )
        }
        return deduplicated(
            enriched + metadata.filter { !primaryIDs.contains($0.id) }
        )
    }

    public static func deduplicated(
        _ sessions: [ResumableAgentSession]
    ) -> [ResumableAgentSession] {
        var latest: [String: ResumableAgentSession] = [:]
        for session in sessions where !session.isArchived {
            if latest[session.id]?.updatedAt ?? .distantPast < session.updatedAt {
                latest[session.id] = session
            }
        }
        return latest.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func filtered(
        _ sessions: [ResumableAgentSession],
        query: String,
        workspace: String?,
        allWorkspaces: Bool
    ) -> [ResumableAgentSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.filter { session in
            let matchesWorkspace = allWorkspaces
                || workspace == nil
                || session.cwd == workspace
            guard matchesWorkspace else { return false }
            guard !needle.isEmpty else { return true }
            return [
                session.displayTitle,
                session.explicitName ?? "",
                session.preview ?? "",
                session.cwd,
                session.model ?? "",
                session.gitBranch ?? "",
                session.sessionID
            ].contains { $0.lowercased().contains(needle) }
        }
    }

    private static func lines(in data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap {
            String($0).data(using: .utf8)
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedBranch(_ value: String?) -> String? {
        guard let branch = normalized(value), branch != "HEAD" else { return nil }
        return branch
    }

    private static func boundedTitle(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        let oneLine = value
            .components(separatedBy: .newlines)
            .first?
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            ) ?? value
        return String(oneLine.prefix(96))
    }

    private static func boundedPreview(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        return String(value.prefix(220))
    }
}
