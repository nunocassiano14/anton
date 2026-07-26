import Foundation

public struct SessionReduction: Equatable, Sendable {
    public var session: AgentSession
    public var didCompleteMainTurn: Bool
    public var requiresInteractiveResponse: Bool

    public init(
        session: AgentSession,
        didCompleteMainTurn: Bool = false,
        requiresInteractiveResponse: Bool = false
    ) {
        self.session = session
        self.didCompleteMainTurn = didCompleteMainTurn
        self.requiresInteractiveResponse = requiresInteractiveResponse
    }
}

public enum SessionReducer {
    public static func reduce(
        existing: AgentSession?,
        request: BridgeRequest,
        now: Date = Date()
    ) -> SessionReduction {
        var session = existing ?? AgentSession(
            agent: request.agent,
            agentSessionID: request.event.sessionID,
            cwd: request.event.cwd,
            model: request.event.model,
            state: .idle,
            startedAt: now,
            terminal: request.terminal
        )

        session.cwd = request.event.cwd
        session.projectName = URL(fileURLWithPath: request.event.cwd).lastPathComponent
        session.model = request.event.model ?? session.model
        session.terminal = mergedTerminal(existing: session.terminal, incoming: request.terminal)
        session.updatedAt = now

        var didCompleteMainTurn = false
        var interactive = false
        let eventName = request.event.name

        switch eventName {
        case "SessionStart":
            session.state = .idle
            session.currentActivity = "Session connected"
            session.interaction = nil

        case "UserPromptSubmit":
            session.state = .working
            session.currentActivity = "Thinking"
            session.interaction = nil

        case "PreToolUse":
            if isQuestionTool(request.event.toolName) {
                let questions = extractQuestions(from: request.event.toolInput)
                session.state = .hasQuestion
                session.currentActivity = "Waiting for your answer"
                session.interaction = PendingInteraction(
                    id: request.requestID,
                    kind: .question,
                    title: questions.first?.header ?? "Question",
                    detail: questions.first?.prompt,
                    questions: questions
                )
                interactive = true
            } else {
                session.state = .working
                session.currentActivity = activityName(for: request.event.toolName)
                session.lastAction = request.event.toolName
                session.interaction = nil
            }

        case "PostToolUse", "PostToolUseFailure", "PostToolBatch":
            session.state = .working
            session.currentActivity = eventName == "PostToolUseFailure" ? "Recovering from a tool error" : "Processing results"
            session.lastAction = request.event.toolName ?? session.lastAction

        case "PermissionRequest":
            let detail = approvalDetail(from: request.event)
            session.state = .needsApproval
            session.currentActivity = "Waiting for approval"
            session.interaction = PendingInteraction(
                id: request.requestID,
                kind: .approval,
                title: request.event.toolName ?? "Permission request",
                detail: detail
            )
            interactive = true

        case "Elicitation":
            let question = elicitationQuestion(from: request.event)
            session.state = .hasQuestion
            session.currentActivity = "Waiting for your answer"
            session.interaction = PendingInteraction(
                id: request.requestID,
                kind: .elicitation,
                title: question.header ?? "Input requested",
                detail: question.prompt,
                questions: [question]
            )
            interactive = true

        case "Stop":
            session.state = .finished
            session.currentActivity = "Ready for the next prompt"
            session.interaction = nil
            session.completedAt = now
            session.lastResponsePreview = preview(request.event.lastAssistantMessage)
            didCompleteMainTurn = true

        case "StopFailure":
            session.state = .error
            session.currentActivity = request.event.error ?? "Agent error"
            session.lastResponsePreview = preview(request.event.lastAssistantMessage)
            session.interaction = nil

        case "SessionEnd":
            session.state = .disconnected
            session.currentActivity = "Session disconnected"
            session.interaction = nil

        case "Notification":
            applyNotification(request.event, to: &session)

        default:
            session.state = .working
            session.currentActivity = eventName
        }

        return SessionReduction(
            session: session,
            didCompleteMainTurn: didCompleteMainTurn,
            requiresInteractiveResponse: interactive
        )
    }

    public static func isQuestionTool(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        let normalized = toolName.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized == "askuserquestion"
            || normalized == "ask_user_question"
            || normalized == "request_user_input"
            || normalized == "tool/requestuserinput"
    }

    private static func mergedTerminal(
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

    private static func activityName(for toolName: String?) -> String {
        guard let toolName, !toolName.isEmpty else { return "Working" }
        let normalized = toolName.lowercased()
        if normalized == "bash" || normalized == "shell" || normalized == "terminal" {
            return "Running a command"
        }
        if normalized == "apply_patch" || normalized == "edit" || normalized == "write" {
            return "Editing files"
        }
        if normalized == "read" || normalized == "view" || normalized == "cat" {
            return "Reading files"
        }
        if normalized.contains("search") || normalized == "grep" || normalized == "glob" {
            return "Searching the project"
        }
        if normalized.contains("test") {
            return "Running tests"
        }
        return "Using \(toolName)"
    }

    private static func approvalDetail(from event: HookEventPayload) -> String? {
        if let description = event.toolInput?["description"]?.stringValue {
            return description
        }
        if let command = event.toolInput?["command"]?.stringValue {
            return command
        }
        return event.toolInput.map { value in
            guard
                let data = try? JSONEncoder().encode(value),
                let text = String(data: data, encoding: .utf8)
            else { return "Review this action in the terminal." }
            return String(text.prefix(300))
        }
    }

    private static func extractQuestions(from input: JSONValue?) -> [AgentQuestion] {
        guard let input else {
            return [AgentQuestion(id: "answer", prompt: "The agent needs your input.")]
        }

        let values: [JSONValue]
        if let questions = input["questions"]?.arrayValue {
            values = questions
        } else {
            values = [input]
        }

        let parsed = values.enumerated().compactMap { index, value -> AgentQuestion? in
            guard let object = value.objectValue else { return nil }
            let prompt = object["question"]?.stringValue
                ?? object["prompt"]?.stringValue
                ?? object["message"]?.stringValue
                ?? "Choose an answer"
            let id = object["id"]?.stringValue ?? prompt
            let header = object["header"]?.stringValue
            let multi = {
                if case .bool(let value) = object["multiSelect"] { return value }
                if case .bool(let value) = object["multi_select"] { return value }
                return false
            }()
            let options = (object["options"]?.arrayValue ?? []).enumerated().map { optionIndex, optionValue in
                let optionObject = optionValue.objectValue
                let label = optionObject?["label"]?.stringValue
                    ?? optionObject?["value"]?.stringValue
                    ?? optionValue.stringValue
                    ?? "Option \(optionIndex + 1)"
                return AgentQuestionOption(
                    id: optionObject?["id"]?.stringValue ?? label,
                    label: label,
                    detail: optionObject?["description"]?.stringValue
                )
            }
            return AgentQuestion(
                id: id.isEmpty ? "question-\(index)" : id,
                header: header,
                prompt: prompt,
                options: options,
                allowsMultiple: multi
            )
        }

        return parsed.isEmpty
            ? [AgentQuestion(id: "answer", prompt: "The agent needs your input.")]
            : parsed
    }

    private static func elicitationQuestion(from event: HookEventPayload) -> AgentQuestion {
        let prompt = event.metadata["message"]?.stringValue ?? "Provide the requested information."
        let schema = event.metadata["requested_schema"]?.objectValue
        let properties = schema?["properties"]?.objectValue ?? [:]
        let options = properties.keys.sorted().map {
            AgentQuestionOption(id: $0, label: properties[$0]?["title"]?.stringValue ?? $0)
        }
        return AgentQuestion(
            id: event.metadata["elicitation_id"]?.stringValue ?? "elicitation",
            header: event.metadata["mcp_server_name"]?.stringValue,
            prompt: prompt,
            options: options
        )
    }

    private static func preview(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(220))
    }

    private static func applyNotification(
        _ event: HookEventPayload,
        to session: inout AgentSession
    ) {
        switch event.metadata["notification_type"]?.stringValue {
        case "permission_prompt":
            session.state = .needsApproval
            session.currentActivity = "Waiting for approval"
        case "idle_prompt":
            session.state = .idle
            session.currentActivity = "Waiting for input"
        case "elicitation_dialog":
            session.state = .hasQuestion
            session.currentActivity = "Waiting for your answer"
        default:
            session.currentActivity = event.metadata["message"]?.stringValue ?? "Notification"
        }
    }
}
