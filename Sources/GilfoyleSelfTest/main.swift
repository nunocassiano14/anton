import Darwin
import Foundation
import GilfoyleCore

private struct TestFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0

    func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("✓ \(name)")
        } catch {
            failed += 1
            print("✗ \(name)")
            print("  \(error.localizedDescription)")
        }
    }

    func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard condition() else {
            throw TestFailure(message: "\(message) (\(file):\(line))")
        }
    }

    func finish() -> Never {
        print("")
        print("\(passed) passed, \(failed) failed")
        Darwin.exit(failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

private final class LockedFlag {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private struct FakeLifecycleAdapter: AgentLifecycleAdapting {
    let agent: AgentKind
    let sessionID: String

    func decode(
        data: Data,
        terminal: TerminalContext,
        token: String
    ) throws -> BridgeRequest {
        BridgeRequest(
            token: token,
            agent: agent,
            event: HookEventPayload(
                name: "SessionStart",
                sessionID: sessionID,
                cwd: "/tmp/fake"
            ),
            terminal: terminal
        )
    }
}

private final class FakeTerminalAdapter: TerminalSessionControlling {
    struct Delivery {
        let text: String
        let route: TerminalSessionRoute
    }

    private(set) var focused: [TerminalSessionRoute] = []
    private(set) var deliveries: [Delivery] = []
    private(set) var closed: [TerminalSessionRoute] = []

    func focus(
        session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            focused.append(try TerminalRouteResolver.resolve(session.terminal))
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func send(
        text: String,
        to session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            deliveries.append(
                Delivery(
                    text: text,
                    route: try TerminalRouteResolver.resolve(session.terminal)
                )
            )
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func close(
        session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            closed.append(try TerminalRouteResolver.resolve(session.terminal))
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }
}

private final class FakeAgentTerminatorProcessOperator:
    AgentProcessOperating,
    @unchecked Sendable
{
    private(set) var currentSnapshot: AgentProcessSnapshot?
    private(set) var signals: [Int32] = []
    private let exitsOnSIGTERM: Bool
    private let replacementAfterWait: AgentProcessSnapshot?
    private var hasWaited = false

    init(
        snapshot: AgentProcessSnapshot,
        exitsOnSIGTERM: Bool = true,
        replacementAfterWait: AgentProcessSnapshot? = nil
    ) {
        self.currentSnapshot = snapshot
        self.exitsOnSIGTERM = exitsOnSIGTERM
        self.replacementAfterWait = replacementAfterWait
    }

    func snapshot(processID: Int32) -> AgentProcessSnapshot? {
        currentSnapshot?.processID == processID ? currentSnapshot : nil
    }

    func send(signal: Int32, to processID: Int32) -> Bool {
        guard currentSnapshot?.processID == processID else { return false }
        signals.append(signal)
        if signal == SIGKILL || (signal == SIGTERM && exitsOnSIGTERM) {
            currentSnapshot = nil
        }
        return true
    }

    func wait(milliseconds: UInt32) {
        if !hasWaited, let replacementAfterWait {
            currentSnapshot = replacementAfterWait
        }
        hasWaited = true
    }
}

private func request(
    agent: AgentKind = .claude,
    event: String,
    toolName: String? = nil,
    toolInput: JSONValue? = nil,
    assistantMessage: String? = nil,
    terminal: TerminalContext = TerminalContext(kind: .terminal, tty: "/dev/ttys001")
) -> BridgeRequest {
    BridgeRequest(
        token: "token",
        requestID: UUID().uuidString,
        agent: agent,
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

private func temporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("anton-self-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func temporaryIPCFolder() throws -> URL {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gf-\(suffix)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func loadObject(_ url: URL) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let dictionary = value as? [String: Any] else {
        throw TestFailure(message: "Expected a JSON object at \(url.path)")
    }
    return dictionary
}

private func serialized(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private let runner = TestRunner()

runner.run("main turn lifecycle and visual completion") {
    var reduction = SessionReducer.reduce(existing: nil, request: request(event: "SessionStart"))
    try runner.require(reduction.session.state == .idle, "SessionStart must produce idle")
    try runner.require(!reduction.didCompleteMainTurn, "SessionStart must not complete a turn")

    reduction = SessionReducer.reduce(
        existing: reduction.session,
        request: request(event: "UserPromptSubmit")
    )
    try runner.require(reduction.session.state == .working, "A submitted prompt must work")

    reduction = SessionReducer.reduce(
        existing: reduction.session,
        request: request(
            event: "PermissionRequest",
            toolName: "Bash",
            toolInput: .object(["command": .string("swift test")])
        )
    )
    try runner.require(reduction.session.state == .needsApproval, "Permission must need approval")
    try runner.require(reduction.requiresInteractiveResponse, "Permission must block for response")
    try runner.require(reduction.session.interaction?.detail == "swift test", "Command must be visible")

    reduction = SessionReducer.reduce(
        existing: reduction.session,
        request: request(event: "Stop", assistantMessage: "Everything is ready.")
    )
    try runner.require(reduction.session.state == .finished, "Stop must finish the main turn")
    try runner.require(reduction.didCompleteMainTurn, "Stop must trigger the visual callout")
    try runner.require(
        reduction.session.lastResponsePreview == "Everything is ready.",
        "The local preview must be retained"
    )
}

runner.run("Codex local rollout state follows the latest task boundary") {
    func event(_ type: String) -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"" + type + "\"}}"
    }
    let working = Data([event("task_complete"), event("task_started")].joined(separator: "\n").utf8)
    let completed = Data([event("task_started"), event("task_complete")].joined(separator: "\n").utf8)
    let unrelated = Data(event("agent_message").utf8)

    try runner.require(
        CodexRolloutLifecycle.state(in: working) == .working,
        "The latest task_started must keep a session working"
    )
    try runner.require(
        CodexRolloutLifecycle.state(in: completed) == .finished,
        "The latest task_complete must mark a session ready"
    )
    try runner.require(
        CodexRolloutLifecycle.state(in: unrelated) == .idle,
        "Non-lifecycle rollout writes must not masquerade as working"
    )
}

runner.run("Codex lifecycle retains turn identity for fast completions") {
    let data = Data(
        """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"old","started_at":100}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"new","started_at":200}}
        """.utf8
    )
    let snapshot = CodexRolloutLifecycle.snapshot(in: data)
    try runner.require(snapshot.state == .finished, "The latest completed task must be ready")
    try runner.require(snapshot.turnID == "new", "The latest task identity must be retained")
    try runner.require(
        snapshot.taskStartedAt == Date(timeIntervalSince1970: 200),
        "The task start time must be retained"
    )
}

runner.run("Codex rollout exposes useful tool activity without command text") {
    let web = Data(
        #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}
        {"type":"response_item","payload":{"type":"function_call","name":"run","arguments":"{\"search_query\":[{\"q\":\"status\"}]}"}}
        """#.utf8
    )
    try runner.require(
        CodexRolloutLifecycle.snapshot(in: web).activity == "Searching the web",
        "Web search should be visible as the live activity"
    )

    let file = Data(
        #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}
        {"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"sed -n '1,120p' Sources/App/NotchRootView.swift\"}"}}
        """#.utf8
    )
    try runner.require(
        CodexRolloutLifecycle.snapshot(in: file).activity == "Reading NotchRootView.swift",
        "File reads should expose only the filename"
    )

    let completed = Data(
        #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"redacted"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn"}}
        """#.utf8
    )
    try runner.require(
        CodexRolloutLifecycle.snapshot(in: completed).activity == "Response ready",
        "Completion must supersede an older tool activity"
    )
}

runner.run("Duplicate TTY inventory rows keep the latest value") {
    let inventory = TerminalInventoryParser.parse(
        terminalLines: [
            "/dev/ttys004|Old title",
            "/dev/ttys004|Current title"
        ],
        iTermLines: [
            "/dev/ttys006|old-session|Old",
            "/dev/ttys006|current-session|Current"
        ]
    )
    try runner.require(
        inventory.terminalTitles["/dev/ttys004"] == "Current title",
        "Duplicate Terminal TTY rows should keep the latest title"
    )
    try runner.require(
        inventory.iTermSessions["/dev/ttys006"]?.identifier == "current-session",
        "Duplicate iTerm TTY rows should keep the latest session"
    )
}

runner.run("Concurrent callouts queue without replacing one another") {
    var queue = PendingCalloutQueue()
    queue.enqueue(sessionID: "finished-a", urgent: false)
    queue.enqueue(sessionID: "finished-b", urgent: false)
    queue.enqueue(sessionID: "approval-a", urgent: true)
    queue.enqueue(sessionID: "approval-b", urgent: true)
    queue.enqueue(sessionID: "finished-b", urgent: false)

    try runner.require(queue.count == 4, "Duplicate session notifications should be coalesced")
    try runner.require(queue.popFirst() == "approval-a", "Urgent work should lead pending callouts")
    try runner.require(queue.popFirst() == "approval-b", "Urgent work should remain FIFO")
    try runner.require(queue.popFirst() == "finished-a", "Normal callouts should preserve FIFO order")
    try runner.require(queue.popFirst() == "finished-b", "Every distinct completion should remain queued")
}

runner.run("CLI discovery supports package-manager wrappers") {
    try runner.require(
        AgentProcessClassifier.agentKind(for: "/opt/homebrew/bin/codex --yolo") == .codex,
        "A direct Codex executable must be recognized"
    )
    try runner.require(
        AgentProcessClassifier.agentKind(
            for: "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
        ) == .codex,
        "A Node-installed Codex executable must be recognized"
    )
    try runner.require(
        AgentProcessClassifier.agentKind(
            for: "/usr/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        ) == .claude,
        "A Node-installed Claude executable must be recognized"
    )
    try runner.require(
        AgentProcessClassifier.agentKind(for: "/Applications/Codex.app/Contents/MacOS/Codex") == nil,
        "The desktop application must not masquerade as a CLI session"
    )
    try runner.require(
        AgentProcessClassifier.agentKind(
            for: "/bin/zsh -lc rg /opt/homebrew/lib/node_modules/@openai/codex/"
        ) == nil,
        "A shell command mentioning a package path must not become a fake agent"
    )
}

runner.run("Response previews preserve Markdown beyond a single line") {
    let message = "## Result\n\n- First item\n- Second item\n\n" + String(repeating: "x", count: 400)
    let reduction = SessionReducer.reduce(
        existing: nil,
        request: request(agent: .codex, event: "Stop", assistantMessage: message)
    )
    try runner.require(
        reduction.session.lastResponsePreview?.contains("## Result\n\n- First item") == true,
        "Markdown structure must survive the hook reducer"
    )
    try runner.require(
        (reduction.session.lastResponsePreview?.count ?? 0) > 220,
        "Useful response text must not be clipped to the old 220-character limit"
    )
}

runner.run("Claude explicit model changes supersede older model metadata") {
    let fixture = Data(
        "{\"model\":\"claude-fable-5\"}\nSet model to **Opus 5 (1M context)** and saved as your default".utf8
    )
    try runner.require(
        AgentModelMetadata.latestClaudeModelChange(in: fixture) == "Opus 5 (1M context)",
        "The newest /model confirmation must replace stale transcript metadata"
    )
    let styledFixture = Data(
        "Set model to \\u001b[1mOpus 5 (1M context)\\u001b[22m and saved as your default".utf8
    )
    try runner.require(
        AgentModelMetadata.latestClaudeModelChange(in: styledFixture) == "Opus 5 (1M context)",
        "ANSI formatting must never appear in the model label"
    )
    let settings = Data("{\"model\":\"opus-5-1m\"}".utf8)
    try runner.require(
        AgentModelMetadata.configuredClaudeModel(in: settings) == "opus-5-1m",
        "The model selected in Claude settings must be available before another API event"
    )
    let styledSettings = Data("{\"model\":\"\\\\u001b[1mOpus 5 (1M context)\\\\u001b[22m\"}".utf8)
    try runner.require(
        AgentModelMetadata.configuredClaudeModel(in: styledSettings) == "Opus 5 (1M context)",
        "Configured model labels must strip terminal formatting too"
    )
}

runner.run("Local agent response previews use the latest assistant reply") {
    let codex = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"Codex result ready\"}}".utf8)
    try runner.require(LocalAgentResponsePreview.codex(in: codex) == "Codex result ready", "Codex completion preview must be shown")
    let claude = Data("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Claude result ready\"}]}}".utf8)
    try runner.require(LocalAgentResponsePreview.claude(in: claude) == "Claude result ready", "Claude completion preview must be shown")
}

runner.run("Claude transcript lifecycle follows the latest user turn") {
    let completed = Data(
        """
        {"type":"user","uuid":"turn-1","timestamp":"2026-07-26T20:32:41.642Z","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"reply","timestamp":"2026-07-26T20:32:50.946Z","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]}}
        """.utf8
    )
    let completedSnapshot = ClaudeTranscriptLifecycle.snapshot(in: completed)
    try runner.require(completedSnapshot.lastUserTurnID == "turn-1", "Claude turn identity must be retained")
    try runner.require(completedSnapshot.hasCompletedLatestTurn, "A later assistant response must complete the current Claude turn")

    let waiting = Data(
        """
        {"type":"assistant","uuid":"old","timestamp":"2026-07-26T20:32:50.946Z","message":{"role":"assistant","content":[{"type":"text","text":"Old reply"}]}}
        {"type":"user","uuid":"turn-2","timestamp":"2026-07-26T20:33:41.642Z","message":{"role":"user","content":"new prompt"}}
        """.utf8
    )
    let waitingSnapshot = ClaudeTranscriptLifecycle.snapshot(in: waiting)
    try runner.require(!waitingSnapshot.hasCompletedLatestTurn, "An old response must not complete a newer Claude prompt")
}

runner.run("Local discovery completion updates the live session once") {
    let terminal = TerminalContext(kind: .terminal, tty: "/dev/ttys007", processID: 777)
    let session = AgentSession(
        agent: .codex,
        agentSessionID: "process-777",
        cwd: "/tmp/anton",
        sessionName: "anton",
        model: "gpt-5.6-terra",
        state: .working,
        terminal: terminal
    )
    let finished = SessionDiscoveryReducer.reduce(
        existing: session,
        cwd: "/tmp/anton",
        sessionName: "anton",
        model: "gpt-5.6-terra",
        state: .finished,
        now: Date(timeIntervalSince1970: 100)
    )
    try runner.require(finished.didCompleteMainTurn, "Working → finished must request one callout")
    try runner.require(finished.session.currentActivity == "Response ready", "Finished state must be visible")
    try runner.require(finished.session.completedAt != nil, "Completion time must be retained")

    let changedModel = SessionDiscoveryReducer.reduce(
        existing: finished.session,
        cwd: "/tmp/anton",
        sessionName: "anton v2",
        model: "gpt-5.7",
        state: .working,
        now: Date(timeIntervalSince1970: 104)
    )
    try runner.require(changedModel.session.model == "gpt-5.7", "A live model change must refresh")
    try runner.require(changedModel.session.sessionName == "anton v2", "A live session rename must refresh")

    let stable = SessionDiscoveryReducer.reduce(
        existing: finished.session,
        cwd: "/tmp/anton",
        sessionName: "anton",
        model: "gpt-5.6-terra",
        state: .finished,
        now: Date(timeIntervalSince1970: 108)
    )
    try runner.require(!stable.didCompleteMainTurn, "Repeated scans must not duplicate a callout")
}

runner.run("Agent session identity acquires its exact live terminal route") {
    let session = AgentSession(
        agent: .claude,
        agentSessionID: "3381ddab-a46f-4636-86e8-47eca94146ee",
        cwd: "/tmp/carlyle",
        sessionName: "carlyle",
        terminal: TerminalContext()
    )
    let discoveredTerminal = TerminalContext(
        kind: .terminal,
        tabTitle: "✳ carlyle",
        tty: "/dev/ttys002",
        processID: 14_056
    )
    try runner.require(
        SessionTerminalAssociation.matches(
            session,
            agent: .claude,
            agentSessionID: "3381ddab-a46f-4636-86e8-47eca94146ee",
            terminal: discoveredTerminal
        ),
        "The durable Claude session ID must join hook state to process discovery"
    )
    try runner.require(
        !SessionTerminalAssociation.matches(
            session,
            agent: .codex,
            agentSessionID: "3381ddab-a46f-4636-86e8-47eca94146ee",
            terminal: discoveredTerminal
        ),
        "The same local ID must never cross agent boundaries"
    )
    let merged = SessionTerminalAssociation.merged(
        existing: session.terminal,
        incoming: discoveredTerminal
    )
    try runner.require(merged.kind == .terminal, "The terminal app kind must be acquired")
    try runner.require(merged.tty == "/dev/ttys002", "The exact TTY must be acquired")
    try runner.require(merged.processID == 14_056, "The live process must be acquired")
}

runner.run("subagent completion does not finish the main turn") {
    let reduction = SessionReducer.reduce(
        existing: nil,
        request: request(event: "SubagentStop", assistantMessage: "Subagent done")
    )
    try runner.require(!reduction.didCompleteMainTurn, "Subagents must not trigger the main callout")
    try runner.require(reduction.session.state != .finished, "Subagents must not finish the main session")
}

runner.run("multiple-choice questions are structured") {
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
    let labels = reduction.session.interaction?.questions.first?.options.map(\.label)
    try runner.require(reduction.session.state == .hasQuestion, "Question must be visible")
    try runner.require(reduction.requiresInteractiveResponse, "Question must wait")
    try runner.require(labels == ["SQLite", "Postgres"], "Question choices must be preserved")
}

runner.run("terminal identity survives sparse events") {
    var reduction = SessionReducer.reduce(
        existing: nil,
        request: request(
            event: "SessionStart",
            terminal: TerminalContext(
                kind: .terminal,
                terminalSessionID: "term-1",
                tty: "/dev/ttys004"
            )
        )
    )
    reduction = SessionReducer.reduce(
        existing: reduction.session,
        request: request(
            event: "UserPromptSubmit",
            terminal: TerminalContext(kind: .terminal, terminalSessionID: "term-1")
        )
    )
    try runner.require(reduction.session.terminal.tty == "/dev/ttys004", "TTY must survive")
    try runner.require(
        reduction.session.terminal.terminalSessionID == "term-1",
        "Terminal session identifier must survive"
    )
}

runner.run("private prompt and transcript fields are never forwarded") {
    let raw: [String: Any] = [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "session",
        "cwd": "/tmp/project",
        "prompt": "TOP SECRET USER PROMPT",
        "transcript_path": "/tmp/private-transcript.jsonl",
        "model": "gpt-test"
    ]
    let parsed = try HookInputParser.parse(
        data: JSONSerialization.data(withJSONObject: raw),
        agent: .codex,
        terminal: TerminalContext(kind: .iTerm),
        token: "token"
    )
    let text = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
    try runner.require(!text.contains("TOP SECRET"), "Prompt leaked into IPC")
    try runner.require(!text.contains("private-transcript"), "Transcript path leaked into IPC")
    try runner.require(parsed.event.toolInput == nil, "Non-interactive tool input must be omitted")
}

runner.run("Claude Stop recovers its response without forwarding the transcript path") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AntonClaudeStop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = directory.appendingPathComponent("session.jsonl")
    try Data(
        """
        {"type":"user","uuid":"turn","timestamp":"2026-07-26T20:32:41.642Z","message":{"role":"user","content":"private prompt"}}
        {"type":"assistant","uuid":"reply","timestamp":"2026-07-26T20:32:50.946Z","message":{"role":"assistant","content":[{"type":"text","text":"Recovered Claude response"}]}}
        """.utf8
    ).write(to: transcript)
    let input = try JSONSerialization.data(
        withJSONObject: [
            "hook_event_name": "Stop",
            "session_id": "session",
            "cwd": "/tmp/project",
            "transcript_path": transcript.path
        ]
    )
    let parsed = try ClaudeLifecycleAdapter().decode(
        data: input,
        terminal: TerminalContext(kind: .terminal),
        token: "token"
    )
    let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
    try runner.require(
        parsed.event.lastAssistantMessage == "Recovered Claude response",
        "Claude's omitted Stop response must be recovered"
    )
    try runner.require(!encoded.contains(transcript.path), "Claude transcript path leaked into IPC")
    try runner.require(!encoded.contains("private prompt"), "Claude prompt leaked into IPC")
}

runner.run("current approval input is retained") {
    let raw: [String: Any] = [
        "hook_event_name": "PermissionRequest",
        "session_id": "session",
        "cwd": "/tmp/project",
        "tool_name": "Bash",
        "tool_input": [
            "command": "swift test",
            "description": "Run project tests"
        ]
    ]
    let parsed = try HookInputParser.parse(
        data: JSONSerialization.data(withJSONObject: raw),
        agent: .codex,
        terminal: TerminalContext(kind: .terminal),
        token: "token"
    )
    try runner.require(
        parsed.event.toolInput?["command"]?.stringValue == "swift test",
        "Current approval command must be visible"
    )
}

runner.run("Claude allow response follows official hook schema") {
    let bridgeRequest = request(event: "PermissionRequest", toolName: "Bash")
    guard let data = try HookResponseRenderer.render(
        request: bridgeRequest,
        response: BridgeResponse(requestID: bridgeRequest.requestID, decision: .allow)
    ) else {
        throw TestFailure(message: "Renderer returned no response")
    }
    let root = try loadJSONDictionary(data)
    let specific = root["hookSpecificOutput"] as? [String: Any]
    let decision = specific?["decision"] as? [String: Any]
    try runner.require(decision?["behavior"] as? String == "allow", "Claude allow schema is wrong")
}

runner.run("Claude question answers are injected into updatedInput") {
    let bridgeRequest = request(
        event: "PreToolUse",
        toolName: "AskUserQuestion",
        toolInput: .object([
            "questions": .array([
                .object(["question": .string("Which framework?")])
            ])
        ])
    )
    guard let data = try HookResponseRenderer.render(
        request: bridgeRequest,
        response: BridgeResponse(
            requestID: bridgeRequest.requestID,
            decision: .answer,
            payload: .object([
                "answers": .object(["Which framework?": .string("SwiftUI")])
            ])
        )
    ) else {
        throw TestFailure(message: "Renderer returned no response")
    }
    let root = try loadJSONDictionary(data)
    let specific = root["hookSpecificOutput"] as? [String: Any]
    let updated = specific?["updatedInput"] as? [String: Any]
    let answers = updated?["answers"] as? [String: String]
    try runner.require(answers?["Which framework?"] == "SwiftUI", "Claude answer was not injected")
}

runner.run("Codex question answer is returned as model feedback") {
    let bridgeRequest = request(
        agent: .codex,
        event: "PreToolUse",
        toolName: "request_user_input",
        toolInput: .object(["questions": .array([])])
    )
    guard let data = try HookResponseRenderer.render(
        request: bridgeRequest,
        response: BridgeResponse(
            requestID: bridgeRequest.requestID,
            decision: .answer,
            payload: .object(["answers": .object(["framework": .string("SwiftUI")])])
        )
    ) else {
        throw TestFailure(message: "Renderer returned no response")
    }
    let root = try loadJSONDictionary(data)
    try runner.require(root["decision"] as? String == "block", "Codex answer must block the tool")
    try runner.require(
        (root["reason"] as? String)?.contains("SwiftUI") == true,
        "Codex feedback must contain the answer"
    )
}

runner.run("Codex Stop emits neutral valid JSON") {
    let bridgeRequest = request(agent: .codex, event: "Stop")
    guard let data = try HookResponseRenderer.render(
        request: bridgeRequest,
        response: BridgeResponse(
            requestID: bridgeRequest.requestID,
            decision: .acknowledge
        )
    ) else {
        throw TestFailure(message: "Codex Stop renderer returned no response")
    }
    let root = try loadJSONDictionary(data)
    try runner.require(root.isEmpty, "Codex Stop response must not continue or alter the turn")
}

runner.run("terminal routing preserves exact tab identity") {
    let terminal = try TerminalRouteResolver.resolve(
        TerminalContext(kind: .terminal, tty: "/dev/ttys009")
    )
    try runner.require(
        terminal == .terminal(tty: "/dev/ttys009"),
        "Terminal route changed its TTY"
    )

    let iTerm = try TerminalRouteResolver.resolve(
        TerminalContext(
            kind: .iTerm,
            iTermSessionID: "w0t1p0:2B0E7F4A-1234",
            tty: "/dev/ttys010"
        )
    )
    try runner.require(
        iTerm == .iTerm(uniqueID: "2B0E7F4A-1234", tty: "/dev/ttys010"),
        "iTerm route did not preserve its unique ID and TTY"
    )
    do {
        _ = try TerminalRouteResolver.resolve(TerminalContext(kind: .unknown))
        throw TestFailure(message: "Unknown terminal route was accepted")
    } catch TerminalRouteError.missingStableIdentifier {
    }
}

runner.run("session termination validates PID, agent, and TTY before signalling") {
    let snapshot = AgentProcessSnapshot(
        processID: 4_242,
        tty: "ttys009",
        arguments: "/opt/homebrew/bin/codex --yolo"
    )
    let process = FakeAgentTerminatorProcessOperator(snapshot: snapshot)
    let session = AgentSession(
        agent: .codex,
        agentSessionID: "termination-test",
        cwd: "/tmp/anton",
        state: .working,
        terminal: TerminalContext(
            kind: .terminal,
            tty: "/dev/ttys009",
            processID: 4_242
        )
    )
    try AgentSessionTerminator(
        processOperator: process,
        pollMilliseconds: 0
    ).terminate(session)
    try runner.require(
        process.signals == [SIGTERM],
        "A validated agent should receive one graceful termination signal"
    )

    let staleProcess = FakeAgentTerminatorProcessOperator(
        snapshot: AgentProcessSnapshot(
            processID: 4_242,
            tty: "ttys009",
            arguments: "/usr/bin/python3 worker.py"
        )
    )
    do {
        try AgentSessionTerminator(
            processOperator: staleProcess,
            pollMilliseconds: 0
        ).terminate(session)
        try runner.require(false, "A stale PID must be rejected")
    } catch AgentSessionTerminationError.agentMismatch {
        try runner.require(
            staleProcess.signals.isEmpty,
            "A process with the wrong executable must never receive a signal"
        )
    }
}

runner.run("stubborn agent termination escalates only after revalidation") {
    let process = FakeAgentTerminatorProcessOperator(
        snapshot: AgentProcessSnapshot(
            processID: 4_243,
            tty: "ttys010",
            arguments: "/usr/local/bin/claude"
        ),
        exitsOnSIGTERM: false
    )
    let session = AgentSession(
        agent: .claude,
        agentSessionID: "stubborn-test",
        cwd: "/tmp/anton",
        state: .working,
        terminal: TerminalContext(
            kind: .terminal,
            tty: "/dev/ttys010",
            processID: 4_243
        )
    )
    try AgentSessionTerminator(
        processOperator: process,
        gracefulPollCount: 1,
        forcedPollCount: 1,
        pollMilliseconds: 0
    ).terminate(session)
    try runner.require(
        process.signals == [SIGTERM, SIGKILL],
        "A still-valid stubborn agent should receive SIGTERM then SIGKILL"
    )
}

runner.run("a reused PID is never force-killed") {
    let replacement = AgentProcessSnapshot(
        processID: 4_244,
        tty: "ttys011",
        arguments: "/usr/bin/python3 replacement.py"
    )
    let process = FakeAgentTerminatorProcessOperator(
        snapshot: AgentProcessSnapshot(
            processID: 4_244,
            tty: "ttys011",
            arguments: "/opt/homebrew/bin/codex --yolo"
        ),
        exitsOnSIGTERM: false,
        replacementAfterWait: replacement
    )
    let session = AgentSession(
        agent: .codex,
        agentSessionID: "pid-reuse-test",
        cwd: "/tmp/anton",
        state: .working,
        terminal: TerminalContext(
            kind: .terminal,
            tty: "/dev/ttys011",
            processID: 4_244
        )
    )
    try AgentSessionTerminator(
        processOperator: process,
        gracefulPollCount: 1,
        forcedPollCount: 1,
        pollMilliseconds: 0
    ).terminate(session)
    try runner.require(
        process.signals == [SIGTERM] && process.currentSnapshot == replacement,
        "A replacement process must survive without receiving SIGKILL"
    )
}

runner.run("background reply scripts do not request terminal focus") {
    for script in [
        TerminalAutomationScripts.terminalSend,
        TerminalAutomationScripts.iTermSend,
        TerminalAutomationScripts.terminalSubmit,
        TerminalAutomationScripts.iTermSubmit,
        TerminalAutomationScripts.terminalClose,
        TerminalAutomationScripts.iTermClose
    ] {
        try runner.require(
            !script.contains("activate")
                && !script.contains("set selected")
                && !script.contains("select terminal"),
            "A reply script must not explicitly focus, select, or activate a terminal"
        )
    }
    try runner.require(
        TerminalAutomationScripts.terminalFocus.contains("activate")
            && TerminalAutomationScripts.iTermFocus.contains("activate"),
        "Only the explicit focus scripts may activate terminal applications"
    )
    try runner.require(
        TerminalAutomationScripts.terminalSend.contains("delay 0.35"),
        "Terminal paste submission must allow the agent TUI to consume the paste"
    )
    try runner.require(
        TerminalAutomationScripts.terminalSubmit.contains("do script \"\"")
            && TerminalAutomationScripts.iTermSubmit.contains("newline yes"),
        "Both terminals must expose a background-only submission retry"
    )
    try runner.require(
        TerminalAutomationScripts.terminalClose.contains("tty of terminalTab is targetTTY")
            && TerminalAutomationScripts.terminalClose.contains("close terminalWindow")
            && TerminalAutomationScripts.terminalClose.contains("do script \"exit\" in terminalTab")
            && TerminalAutomationScripts.iTermClose.contains("write terminalSession text \"exit\" newline yes"),
        "Ended agents must close only their exact Terminal/iTerm session"
    )
    try runner.require(
        TerminalAutomationScripts.terminalLaunch.contains("do script commandText")
            && TerminalAutomationScripts.iTermLaunch.contains(
                "default profile command commandText"
            ),
        "Session creation must use the terminals' native scripting APIs"
    )
    try runner.require(
        !TerminalAutomationScripts.terminalLaunch.lowercased().contains("keystroke")
            && !TerminalAutomationScripts.iTermLaunch.lowercased().contains("keystroke"),
        "Session creation must never depend on Accessibility keystrokes"
    )
}

runner.run("attention cards open once but always remain collapsible") {
    let opened = SessionDisclosurePolicy.initial(
        expandedByDefault: false,
        state: .finished
    )
    try runner.require(
        opened && !SessionDisclosurePolicy.toggled(opened),
        "A ready response should open initially and close when the user clicks"
    )
    try runner.require(
        !SessionDisclosurePolicy.afterStateChange(
            current: false,
            state: .working
        ),
        "Ordinary updates must not reopen a card the user collapsed"
    )
    try runner.require(
        SessionDisclosurePolicy.afterStateChange(
            current: false,
            state: .needsApproval
        ),
        "A fresh attention state should reveal the session once"
    )
}

runner.run("numbered Markdown lists keep one continuous sequence") {
    let blocks = MarkdownBlockParser.parse(
        """
        1. First market

           Supporting evidence for the first market.

        1. Second market

           Supporting evidence for the second market.

        1. Third market
        """
    )
    try runner.require(
        blocks == [
            .list(
                [
                    "First market\n\nSupporting evidence for the first market.",
                    "Second market\n\nSupporting evidence for the second market.",
                    "Third market"
                ],
                ordered: true,
                start: 1
            )
        ],
        "Continuation paragraphs must not reset ordered-list numbering"
    )
}

runner.run("separate ordered Markdown blocks keep their source numbers") {
    let blocks = MarkdownBlockParser.parse(
        """
        1. First market
        Evidence for the first market.

        2. Second market
        Evidence for the second market.

        3. Third market
        """
    )
    try runner.require(
        blocks == [
            .list(["First market"], ordered: true, start: 1),
            .text("Evidence for the first market."),
            .list(["Second market"], ordered: true, start: 2),
            .text("Evidence for the second market."),
            .list(["Third market"], ordered: true, start: 3)
        ],
        "Each ordered block must retain the number emitted by the agent"
    )
}

runner.run("response preview normalization preserves Markdown indentation") {
    let message = """
    1. First market

       Supporting evidence for the first market.

    1. Second market
    """
    let reduction = SessionReducer.reduce(
        existing: nil,
        request: request(agent: .codex, event: "Stop", assistantMessage: message)
    )
    try runner.require(
        reduction.session.lastResponsePreview?
            .contains("\n   Supporting evidence for the first market.") == true,
        "The response preview must retain list-continuation indentation"
    )
    try runner.require(
        MarkdownBlockParser.parse(reduction.session.lastResponsePreview ?? "")
            == [
                .list(
                    [
                        "First market\n\nSupporting evidence for the first market.",
                        "Second market"
                    ],
                    ordered: true,
                    start: 1
                )
            ],
        "The normalized preview must still parse as one continuous ordered list"
    )
}

runner.run("interaction responses route only to the matching request") {
    let broker = InteractionResponseBroker()
    var approval: BridgeResponse?
    var question: BridgeResponse?
    broker.register(requestID: "approval") { approval = $0 }
    broker.register(requestID: "question") { question = $0 }

    let answered = broker.resolve(
        requestID: "question",
        response: BridgeResponse(
            requestID: "question",
            decision: .answer,
            payload: .object(["answer": .string("SwiftUI")])
        )
    )
    try runner.require(answered, "Question response was not delivered")
    try runner.require(approval == nil, "Question response leaked to approval")
    try runner.require(question?.decision == .answer, "Question response changed")
    try runner.require(broker.pendingCount == 1, "Wrong pending response was removed")

    let denied = broker.resolve(
        requestID: "approval",
        response: BridgeResponse(requestID: "approval", decision: .deny)
    )
    try runner.require(denied, "Approval response was not delivered")
    try runner.require(approval?.decision == .deny, "Approval response changed")
    try runner.require(broker.pendingCount == 0, "Broker did not drain")
}

runner.run("daily-use settings persist together") {
    let suiteName = "AntonSelfTest.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw TestFailure(message: "Could not create isolated UserDefaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let expected = StoredPreferences(
        shortcut: ShortcutConfiguration(
            keyCode: 11,
            command: true,
            option: false,
            control: true,
            shift: true
        ),
        onboardingComplete: true,
        lastLaunchAgent: .codex,
        lastLaunchWorkspace: "/tmp/anton",
        lastLaunchTerminal: .iTerm
    )
    try PreferencesRepository(defaults: defaults).save(expected)
    let loaded = PreferencesRepository(defaults: defaults).load()
    try runner.require(loaded == expected, "Persisted settings did not round-trip")
}

runner.run("Anton adopts preferences from the previous local build") {
    let suiteName = "AntonMigrationSelfTest.\(UUID().uuidString)"
    let legacySuiteName = "GilfoyleMigrationSelfTest.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw TestFailure(message: "Could not create isolated UserDefaults suite")
    }
    guard let legacyDefaults = UserDefaults(suiteName: legacySuiteName) else {
        throw TestFailure(message: "Could not create isolated legacy UserDefaults suite")
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }
    let expected = StoredPreferences(onboardingComplete: true)
    legacyDefaults.set(try JSONEncoder().encode(expected), forKey: PreferencesRepository.legacyKey)
    try runner.require(
        PreferencesRepository(defaults: defaults, legacyDefaults: legacyDefaults).load() == expected,
        "Anton did not migrate prior local preferences"
    )
}

runner.run("Claude and Codex lifecycle adapters retain their identity") {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "hook_event_name": "SessionStart",
            "session_id": "session",
            "cwd": "/tmp/project"
        ]
    )
    let terminal = TerminalContext(kind: .terminal, tty: "/dev/ttys001")
    let claude = try ClaudeLifecycleAdapter().decode(
        data: data,
        terminal: terminal,
        token: "token"
    )
    let codex = try CodexLifecycleAdapter().decode(
        data: data,
        terminal: terminal,
        token: "token"
    )
    try runner.require(claude.agent == .claude, "Claude adapter mislabeled its event")
    try runner.require(codex.agent == .codex, "Codex adapter mislabeled its event")
}

runner.run("fake agent adapters isolate Claude and Codex sessions") {
    let terminal = TerminalContext(kind: .terminal, tty: "/dev/ttys001")
    let claude = try FakeLifecycleAdapter(
        agent: .claude,
        sessionID: "claude-fake"
    ).decode(data: Data(), terminal: terminal, token: "token")
    let codex = try FakeLifecycleAdapter(
        agent: .codex,
        sessionID: "codex-fake"
    ).decode(data: Data(), terminal: terminal, token: "token")
    try runner.require(claude.agent == .claude, "Fake Claude adapter crossed agent identity")
    try runner.require(codex.agent == .codex, "Fake Codex adapter crossed agent identity")
    try runner.require(
        claude.event.sessionID != codex.event.sessionID,
        "Fake agent sessions were conflated"
    )
}

runner.run("fake terminal adapter sends only to the selected session") {
    let fake = FakeTerminalAdapter()
    let terminalSession = AgentSession(
        agent: .claude,
        agentSessionID: "terminal-session",
        cwd: "/tmp/one",
        terminal: TerminalContext(kind: .terminal, tty: "/dev/ttys001")
    )
    let iTermSession = AgentSession(
        agent: .codex,
        agentSessionID: "iterm-session",
        cwd: "/tmp/two",
        terminal: TerminalContext(
            kind: .iTerm,
            iTermSessionID: "w0t0p0:TARGET",
            tty: "/dev/ttys002"
        )
    )

    fake.send(text: "continue", to: iTermSession) { _ in }
    try runner.require(fake.deliveries.count == 1, "Reply produced multiple deliveries")
    try runner.require(fake.deliveries.first?.text == "continue", "Reply text changed")
    try runner.require(
        fake.deliveries.first?.route == .iTerm(uniqueID: "TARGET", tty: "/dev/ttys002"),
        "Reply targeted the wrong iTerm session"
    )
    let otherRoute = try TerminalRouteResolver.resolve(terminalSession.terminal)
    try runner.require(
        fake.deliveries.first?.route != otherRoute,
        "Reply leaked to the Terminal session"
    )
    fake.submit(session: terminalSession) { _ in }
    try runner.require(fake.deliveries.count == 2, "Submission retry was not delivered")
    try runner.require(fake.deliveries.last?.text == "", "Submission retry inserted extra text")
    try runner.require(
        fake.deliveries.last?.route == otherRoute,
        "Submission retry targeted the wrong session"
    )
    fake.close(session: terminalSession) { _ in }
    try runner.require(
        fake.closed == [.terminal(tty: "/dev/ttys001")],
        "Session closure targeted the wrong terminal"
    )
}

runner.run("Claude integration is idempotent and reversible") {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = IntegrationInstaller(
        homeURL: home,
        helperURL: URL(fileURLWithPath: "/Applications/Anton.app/Contents/Helpers/anton-hook"),
        backupsURL: home.appendingPathComponent("Backups")
    )
    let settingsURL = installer.claudeSettingsURL
    try FileManager.default.createDirectory(
        at: settingsURL.deletingLastPathComponent(),
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
    try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)

    let change = try installer.installClaude()
    try runner.require(change.changed, "First install must change settings")
    try runner.require(change.backupURL != nil, "Existing settings must be backed up")
    try runner.require(installer.status(for: .claude).state == .installed, "Install must be complete")

    var installed = try loadObject(settingsURL)
    try runner.require(installed["model"] as? String == "claude-test", "Model setting was lost")
    try runner.require(installed["theme"] as? String == "dark", "Theme setting was lost")
    var installedText = try serialized(installed)
    try runner.require(installedText.contains("company-policy"), "Existing hook was lost")
    try runner.require(installedText.contains("anton-hook"), "Anton hook is absent")

    let duplicate = try installer.installClaude()
    try runner.require(!duplicate.changed, "Repeated install must be idempotent")

    let relocated = IntegrationInstaller(
        homeURL: home,
        helperURL: URL(fileURLWithPath: "/Users/test/Applications/Anton.app/Contents/Helpers/anton-hook"),
        backupsURL: home.appendingPathComponent("Backups")
    )
    try runner.require(
        relocated.status(for: .claude).state == .incomplete,
        "A moved app must require integration repair"
    )
    let repair = try relocated.installClaude()
    try runner.require(repair.changed, "Repair must update the helper location")
    installed = try loadObject(settingsURL)
    installedText = try serialized(installed)
        .replacingOccurrences(of: "\\/", with: "/")
    try runner.require(
        installedText.contains("/Users/test/Applications/Anton.app"),
        "Repair did not install the new helper path"
    )
    try runner.require(
        !installedText.contains("'/Applications/Anton.app"),
        "Repair left the stale helper path"
    )
    let repeatedRepair = try relocated.installClaude()
    try runner.require(!repeatedRepair.changed, "Repaired integration must become idempotent")

    let removal = try relocated.removeClaude()
    try runner.require(removal.changed, "Removal must change settings")
    installed = try loadObject(settingsURL)
    installedText = try serialized(installed)
    try runner.require(installedText.contains("company-policy"), "Removal deleted another hook")
    try runner.require(!installedText.contains("anton-hook"), "Removal left Anton hooks")
}

runner.run("Codex hook file is created and removed cleanly") {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = IntegrationInstaller(
        homeURL: home,
        helperURL: URL(fileURLWithPath: "/Applications/Anton.app/Contents/Helpers/anton-hook"),
        backupsURL: home.appendingPathComponent("Backups")
    )
    try runner.require(
        !FileManager.default.fileExists(atPath: installer.codexHooksURL.path),
        "Codex fixture must start empty"
    )
    _ = try installer.installCodex()
    try runner.require(installer.status(for: .codex).state == .installed, "Codex install is incomplete")
    _ = try installer.removeCodex()
    try runner.require(
        !FileManager.default.fileExists(atPath: installer.codexHooksURL.path),
        "Anton-only Codex hook file must be removed"
    )
}

runner.run("local Claude history exposes resumable sessions without a terminal") {
    let data = """
    {"display":"Earlier turn","project":"/tmp/anton","sessionId":"claude-local","timestamp":1000}
    {"display":"Latest turn","project":"/tmp/anton","sessionId":"claude-local","timestamp":3000}
    """.data(using: .utf8) ?? Data()
    let sessions = ResumableSessionParser.claudeHistory(data)
    try runner.require(sessions.count == 1, "Claude history was not deduplicated")
    try runner.require(sessions[0].title == "Latest turn", "Latest Claude title was not selected")
    try runner.require(
        sessions[0].displayTitle == "Claude Code · anton",
        "Prompt text leaked into the visible Claude title"
    )
    try runner.require(sessions[0].cwd == "/tmp/anton", "Claude workspace was lost")
}

runner.run("resume titles prefer explicit rename, then branch, never prompt text") {
    let renamed = ResumableAgentSession(
        agent: .codex,
        sessionID: "renamed",
        title: "Do not show this first prompt",
        explicitName: "Anton",
        cwd: "/tmp/anton",
        updatedAt: Date(),
        gitBranch: "feature/resume"
    )
    let branched = ResumableAgentSession(
        agent: .claude,
        sessionID: "branched",
        title: "/resume old-session",
        cwd: "/tmp/anton",
        updatedAt: Date(),
        gitBranch: "feature/resume"
    )
    try runner.require(renamed.displayTitle == "Anton", "Explicit rename did not win")
    try runner.require(
        branched.displayTitle == "feature/resume",
        "Git branch was not used for an unnamed session"
    )
}

runner.run("Claude custom-title metadata is extracted locally") {
    let data = """
    {"type":"user","sessionId":"claude-local","gitBranch":"feature/old"}
    {"type":"custom-title","sessionId":"claude-local","customTitle":"Baltic design"}
    {"type":"assistant","sessionId":"claude-local","gitBranch":"feature/current"}
    """.data(using: .utf8) ?? Data()
    let metadata = ResumableSessionParser.claudeTranscriptMetadata(data)
    try runner.require(metadata.explicitName == "Baltic design", "Claude /rename was missed")
    try runner.require(
        metadata.gitBranch == "feature/current",
        "Latest Claude branch was missed"
    )
}

runner.run("new session command is quoted and carries only the launch token") {
    let plan = AgentSessionLaunchPlan(
        launchToken: "launch-token",
        agent: .claude,
        mode: .new,
        executablePath: "/opt/bin/claude",
        cwd: "/tmp/Nuno's repo",
        sessionName: "Designer's review",
        terminalKind: .terminal
    )
    let command = try AgentLaunchCommandBuilder.command(for: plan)
    try runner.require(
        command.contains("'/tmp/Nuno'\\''s repo'"),
        "Workspace path was not safely quoted"
    )
    try runner.require(
        command.contains("'ANTON_LAUNCH_TOKEN=launch-token'"),
        "Launch handshake token is missing"
    )
    try runner.require(
        !command.contains("initial prompt"),
        "An initial prompt leaked into process arguments"
    )
}

runner.run("new sessions switch to the selected Git branch before launch") {
    let plan = AgentSessionLaunchPlan(
        launchToken: "branch-token",
        agent: .codex,
        mode: .new,
        executablePath: "/opt/bin/codex",
        cwd: "/tmp/repo",
        gitBranch: "feature/Nuno's-launcher",
        terminalKind: .terminal
    )
    let command = try AgentLaunchCommandBuilder.command(for: plan)
    try runner.require(
        command.hasPrefix(
            "cd -- '/tmp/repo' && /usr/bin/git switch -- "
                + "'feature/Nuno'\\''s-launcher' && exec "
        ),
        "Selected Git branch was not switched safely before agent launch"
    )
}

runner.run("resume and fork use native Claude and Codex commands") {
    func command(
        agent: AgentKind,
        mode: AgentSessionLaunchMode
    ) throws -> String {
        try AgentLaunchCommandBuilder.command(
            for: AgentSessionLaunchPlan(
                launchToken: "token",
                agent: agent,
                mode: mode,
                executablePath: agent == .claude ? "/opt/bin/claude" : "/opt/bin/codex",
                cwd: "/tmp/repo",
                priorSessionID: "saved-id",
                terminalKind: .terminal
            )
        )
    }
    let claudeResume = try command(agent: .claude, mode: .resume)
    let claudeFork = try command(agent: .claude, mode: .fork)
    let codexResume = try command(agent: .codex, mode: .resume)
    let codexFork = try command(agent: .codex, mode: .fork)
    try runner.require(
        claudeResume.hasSuffix("'--resume' 'saved-id'"),
        "Claude resume command is incorrect"
    )
    try runner.require(
        claudeFork.hasSuffix("'--resume' 'saved-id' '--fork-session'"),
        "Claude fork command is incorrect"
    )
    try runner.require(
        codexResume.hasSuffix("'resume' 'saved-id'"),
        "Codex resume command is incorrect"
    )
    try runner.require(
        codexFork.hasSuffix("'fork' 'saved-id'"),
        "Codex fork command is incorrect"
    )
}

runner.run("authenticated IPC round trip uses a private socket") {
    let folder = try temporaryIPCFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let socketURL = folder.appendingPathComponent("bridge.sock")
    let server = UnixSocketServer(socketURL: socketURL)
    defer { server.stop() }
    try server.start(token: "correct-token") { bridgeRequest, respond in
        respond(
            BridgeResponse(
                requestID: bridgeRequest.requestID,
                decision: .acknowledge
            )
        )
    }
    let bridgeRequest = BridgeRequest(
        token: "correct-token",
        agent: .codex,
        event: HookEventPayload(
            name: "SessionStart",
            sessionID: "session",
            cwd: "/tmp/project"
        ),
        terminal: TerminalContext(kind: .iTerm)
    )
    let response = try UnixSocketClient(socketURL: socketURL).send(bridgeRequest)
    try runner.require(response.decision == .acknowledge, "IPC acknowledgement failed")
    try runner.require(response.requestID == bridgeRequest.requestID, "IPC request ID changed")
    let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    try runner.require(permissions == 0o600, "Socket permissions must be 0600")
}

runner.run("invalid IPC token is rejected before the app handler") {
    let folder = try temporaryIPCFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let socketURL = folder.appendingPathComponent("bridge.sock")
    let server = UnixSocketServer(socketURL: socketURL)
    defer { server.stop() }
    let called = LockedFlag()
    try server.start(token: "correct-token") { bridgeRequest, respond in
        called.set()
        respond(BridgeResponse(requestID: bridgeRequest.requestID, decision: .allow))
    }
    let bridgeRequest = BridgeRequest(
        token: "wrong-token",
        agent: .claude,
        event: HookEventPayload(
            name: "SessionStart",
            sessionID: "session",
            cwd: "/tmp/project"
        ),
        terminal: TerminalContext()
    )
    let response = try UnixSocketClient(socketURL: socketURL).send(bridgeRequest)
    try runner.require(response.decision == .deny, "Invalid token must be denied")
    try runner.require(!called.value, "Application handler saw an unauthenticated request")
}

runner.run("duplicate startup cannot unlink or steal the live IPC socket") {
    let folder = try temporaryIPCFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let socketURL = folder.appendingPathComponent("bridge.sock")
    let live = UnixSocketServer(socketURL: socketURL)
    defer { live.stop() }
    try live.start(token: "token") { request, respond in
        respond(BridgeResponse(requestID: request.requestID, decision: .acknowledge))
    }

    let duplicate = UnixSocketServer(socketURL: socketURL)
    duplicate.stop()
    var duplicateWasRejected = false
    do {
        try duplicate.start(token: "other") { _, _ in }
    } catch {
        duplicateWasRejected = true
    }
    duplicate.stop()
    try runner.require(duplicateWasRejected, "A duplicate Anton process stole the active socket")

    let request = BridgeRequest(
        token: "token",
        agent: .claude,
        event: HookEventPayload(
            name: "SessionStart",
            sessionID: "session",
            cwd: "/tmp/project"
        ),
        terminal: TerminalContext()
    )
    let response = try UnixSocketClient(socketURL: socketURL).send(request)
    try runner.require(response.decision == .acknowledge, "The original IPC bridge was unlinked")
}

runner.finish()

private func loadJSONDictionary(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
        throw TestFailure(message: "Expected JSON dictionary output")
    }
    return dictionary
}
