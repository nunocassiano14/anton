import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

public enum TerminalKind: String, Codable, Sendable {
    case terminal
    case iTerm
    case unknown

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm: return "iTerm"
        case .unknown: return "Terminal desconhecido"
        }
    }
}

public enum AgentSessionState: String, Codable, CaseIterable, Sendable {
    case working
    case needsApproval
    case hasQuestion
    case finished
    case idle
    case error
    case disconnected

    public var displayName: String {
        switch self {
        case .working: return "Working"
        case .needsApproval: return "Needs approval"
        case .hasQuestion: return "Has a question"
        case .finished: return "Ready"
        case .idle: return "Idle"
        case .error: return "Error"
        case .disconnected: return "Disconnected"
        }
    }

    public var needsUser: Bool {
        self == .needsApproval || self == .hasQuestion || self == .finished || self == .error
    }
}

public struct TerminalContext: Codable, Equatable, Sendable {
    public var kind: TerminalKind
    public var termProgram: String?
    public var terminalSessionID: String?
    public var iTermSessionID: String?
    /// User-visible tab/session title, read locally from Terminal or iTerm.
    public var tabTitle: String?
    public var tty: String?
    public var processID: Int32?
    public var parentProcessID: Int32?

    public init(
        kind: TerminalKind = .unknown,
        termProgram: String? = nil,
        terminalSessionID: String? = nil,
        iTermSessionID: String? = nil,
        tabTitle: String? = nil,
        tty: String? = nil,
        processID: Int32? = nil,
        parentProcessID: Int32? = nil
    ) {
        self.kind = kind
        self.termProgram = termProgram
        self.terminalSessionID = terminalSessionID
        self.iTermSessionID = iTermSessionID
        self.tabTitle = tabTitle
        self.tty = tty
        self.processID = processID
        self.parentProcessID = parentProcessID
    }
}

/// Joins an agent's durable local session identity to the live terminal route
/// discovered from its process. Hooks can know the Claude/Codex session ID
/// before they know the TTY, while process discovery observes the inverse.
/// Treating either half as a separate session makes an otherwise live session
/// impossible to target from Anton.
public enum SessionTerminalAssociation {
    public static func matches(
        _ session: AgentSession,
        agent: AgentKind,
        agentSessionID: String? = nil,
        terminal: TerminalContext
    ) -> Bool {
        guard session.agent == agent else { return false }

        if let agentSessionID = normalized(agentSessionID),
           normalized(session.agentSessionID) == agentSessionID {
            return true
        }

        if let lhs = session.terminal.processID,
           let rhs = terminal.processID,
           lhs == rhs {
            return true
        }

        guard let lhsTTY = normalized(session.terminal.tty),
              let rhsTTY = normalized(terminal.tty)
        else {
            return false
        }
        return lhsTTY == rhsTTY
    }

    public static func merged(
        existing: TerminalContext,
        incoming: TerminalContext
    ) -> TerminalContext {
        TerminalContext(
            kind: incoming.kind == .unknown ? existing.kind : incoming.kind,
            termProgram: incoming.termProgram ?? existing.termProgram,
            terminalSessionID: incoming.terminalSessionID ?? existing.terminalSessionID,
            iTermSessionID: incoming.iTermSessionID ?? existing.iTermSessionID,
            tabTitle: incoming.tabTitle ?? existing.tabTitle,
            tty: incoming.tty ?? existing.tty,
            processID: incoming.processID ?? existing.processID,
            parentProcessID: incoming.parentProcessID ?? existing.parentProcessID
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct HookEventPayload: Codable, Equatable, Sendable {
    public var name: String
    public var sessionID: String
    public var turnID: String?
    public var cwd: String
    public var model: String?
    public var permissionMode: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var lastAssistantMessage: String?
    public var error: String?
    public var metadata: [String: JSONValue]

    public init(
        name: String,
        sessionID: String,
        turnID: String? = nil,
        cwd: String,
        model: String? = nil,
        permissionMode: String? = nil,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        lastAssistantMessage: String? = nil,
        error: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.toolName = toolName
        self.toolInput = toolInput
        self.lastAssistantMessage = lastAssistantMessage
        self.error = error
        self.metadata = metadata
    }
}

public struct AgentQuestionOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct AgentQuestion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var header: String?
    public var prompt: String
    public var options: [AgentQuestionOption]
    public var allowsMultiple: Bool

    public init(
        id: String,
        header: String? = nil,
        prompt: String,
        options: [AgentQuestionOption] = [],
        allowsMultiple: Bool = false
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.options = options
        self.allowsMultiple = allowsMultiple
    }
}

public enum InteractionKind: String, Codable, Sendable {
    case approval
    case question
    case elicitation
}

public struct PendingInteraction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: InteractionKind
    public var title: String
    public var detail: String?
    public var questions: [AgentQuestion]

    public init(
        id: String,
        kind: InteractionKind,
        title: String,
        detail: String? = nil,
        questions: [AgentQuestion] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.questions = questions
    }
}

public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var agentSessionID: String
    public var sessionName: String?
    public var projectName: String
    public var cwd: String
    public var model: String?
    public var state: AgentSessionState
    public var currentActivity: String?
    public var lastAction: String?
    public var lastResponsePreview: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var terminal: TerminalContext
    public var interaction: PendingInteraction?

    public init(
        agent: AgentKind,
        agentSessionID: String,
        cwd: String,
        sessionName: String? = nil,
        model: String? = nil,
        state: AgentSessionState = .idle,
        startedAt: Date = Date(),
        terminal: TerminalContext = TerminalContext()
    ) {
        self.id = "\(agent.rawValue):\(agentSessionID)"
        self.agent = agent
        self.agentSessionID = agentSessionID
        self.sessionName = sessionName
        self.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        self.cwd = cwd
        self.model = model
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.terminal = terminal
    }
}
