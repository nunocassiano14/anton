import Foundation
import Testing
@testable import GilfoyleCore

@Suite("Session reducer")
struct SessionReducerTests {
    @Test("Main turn transitions and reports visual completion")
    func mainTurnLifecycleAndVisualCompletion() {
        let start = request(event: "SessionStart")
        var reduction = SessionReducer.reduce(existing: nil, request: start)
        #expect(reduction.session.state == .idle)
        #expect(!reduction.didCompleteMainTurn)

        reduction = SessionReducer.reduce(
            existing: reduction.session,
            request: request(event: "UserPromptSubmit")
        )
        #expect(reduction.session.state == .working)

        reduction = SessionReducer.reduce(
            existing: reduction.session,
            request: request(
                event: "PermissionRequest",
                toolName: "Bash",
                toolInput: .object(["command": .string("swift test")])
            )
        )
        #expect(reduction.session.state == .needsApproval)
        #expect(reduction.requiresInteractiveResponse)
        #expect(reduction.session.interaction?.detail == "swift test")

        reduction = SessionReducer.reduce(
            existing: reduction.session,
            request: request(event: "Stop", assistantMessage: "Everything is ready.")
        )
        #expect(reduction.session.state == .finished)
        #expect(reduction.session.lastResponsePreview == "Everything is ready.")
        #expect(reduction.didCompleteMainTurn)
        #expect(!reduction.requiresInteractiveResponse)
    }

    @Test("Subagent completion does not finish the main turn")
    func subagentStopDoesNotCompleteMainTurn() {
        let reduction = SessionReducer.reduce(
            existing: nil,
            request: request(event: "SubagentStop", assistantMessage: "Subagent done")
        )
        #expect(!reduction.didCompleteMainTurn)
        #expect(reduction.session.state != .finished)
    }

    @Test("Stop without embedded text keeps the response already recovered locally")
    func sparseStopPreservesRecoveredResponse() {
        var existing = AgentSession(
            agent: .claude,
            agentSessionID: "session",
            cwd: "/tmp/project",
            state: .working
        )
        existing.lastResponsePreview = "Recovered from Claude transcript"

        let reduction = SessionReducer.reduce(
            existing: existing,
            request: request(event: "Stop")
        )

        #expect(reduction.session.state == .finished)
        #expect(reduction.session.lastResponsePreview == "Recovered from Claude transcript")
    }

    @Test("Claude multiple-choice questions are structured")
    func claudeQuestionIsStructured() {
        let input: JSONValue = .object([
            "questions": .array([
                .object([
                    "question": .string("Which database?"),
                    "header": .string("Database"),
                    "options": .array([
                        .object([
                            "label": .string("SQLite"),
                            "description": .string("Local and simple")
                        ]),
                        .object(["label": .string("Postgres")])
                    ]),
                    "multiSelect": .bool(false)
                ])
            ])
        ])
        let reduction = SessionReducer.reduce(
            existing: nil,
            request: request(event: "PreToolUse", toolName: "AskUserQuestion", toolInput: input)
        )

        #expect(reduction.session.state == .hasQuestion)
        #expect(reduction.requiresInteractiveResponse)
        #expect(reduction.session.interaction?.questions.first?.prompt == "Which database?")
        #expect(
            reduction.session.interaction?.questions.first?.options.map(\.label)
                == ["SQLite", "Postgres"]
        )
    }

    @Test("A question arriving after Stop supersedes the completed composer")
    func questionAfterStopOwnsTheNextInput() {
        var reduction = SessionReducer.reduce(
            existing: nil,
            request: request(event: "Stop", assistantMessage: "Before I continue…")
        )
        #expect(reduction.didCompleteMainTurn)
        #expect(reduction.session.state == .finished)

        reduction = SessionReducer.reduce(
            existing: reduction.session,
            request: request(
                event: "PreToolUse",
                toolName: "request_user_input",
                toolInput: .object([
                    "questions": .array([
                        .object([
                            "id": .string("streaming"),
                            "question": .string("Should streaming be real?"),
                            "options": .array([
                                .object(["label": .string("Guided")]),
                                .object(["label": .string("Real")])
                            ])
                        ])
                    ])
                ])
            )
        )

        #expect(reduction.requiresInteractiveResponse)
        #expect(reduction.session.state == .hasQuestion)
        #expect(reduction.session.interaction?.questions.first?.options.count == 2)
        #expect(!PromptSubmissionPolicy.canDeliverQueuedPrompt(to: reduction.session))
    }

    @Test("Terminal identity survives sparse later events")
    func terminalIdentityIsMergedWithoutLosingKnownTTY() {
        let initialTerminal = TerminalContext(
            kind: .terminal,
            terminalSessionID: "term-1",
            tty: "/dev/ttys004"
        )
        var reduction = SessionReducer.reduce(
            existing: nil,
            request: request(event: "SessionStart", terminal: initialTerminal)
        )

        reduction = SessionReducer.reduce(
            existing: reduction.session,
            request: request(
                event: "UserPromptSubmit",
                terminal: TerminalContext(kind: .terminal, terminalSessionID: "term-1")
            )
        )

        #expect(reduction.session.terminal.tty == "/dev/ttys004")
        #expect(reduction.session.terminal.terminalSessionID == "term-1")
    }

    private func request(
        event: String,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        assistantMessage: String? = nil,
        terminal: TerminalContext = TerminalContext(kind: .terminal, tty: "/dev/ttys001")
    ) -> BridgeRequest {
        BridgeRequest(
            token: "token",
            requestID: UUID().uuidString,
            agent: .claude,
            event: HookEventPayload(
                name: event,
                sessionID: "session-1",
                cwd: "/tmp/project",
                model: "test-model",
                toolName: toolName,
                toolInput: toolInput,
                lastAssistantMessage: assistantMessage
            ),
            terminal: terminal
        )
    }
}
