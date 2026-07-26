import Foundation
import Testing
@testable import GilfoyleCore

@Suite("Local agent discovery parsing")
struct DiscoveryParsingTests {
    @Test("duplicate TTY inventory rows keep the latest valid value")
    func duplicateTTYInventoryRowsKeepLatestValue() {
        let inventory = TerminalInventoryParser.parse(
            terminalLines: [
                "/dev/ttys004|Old title",
                "/dev/ttys004|Current title",
                "/dev/ttys005|Other tab"
            ],
            iTermLines: [
                "/dev/ttys006|old-session|Old",
                "/dev/ttys006|current-session|Current",
                "/dev/ttys007|untitled-session|"
            ]
        )

        #expect(inventory.terminalTitles["/dev/ttys004"] == "Current title")
        #expect(inventory.terminalTitles["/dev/ttys005"] == "Other tab")
        #expect(inventory.iTermSessions["/dev/ttys006"]?.identifier == "current-session")
        #expect(inventory.iTermSessions["/dev/ttys006"]?.title == "Current")
        #expect(inventory.iTermSessions["/dev/ttys007"]?.title == nil)
    }

    @Test("CLI agents are recognized when launched directly or through Node")
    func processClassificationHandlesPackageManagerWrappers() {
        #expect(AgentProcessClassifier.agentKind(for: "/opt/homebrew/bin/codex --yolo") == .codex)
        #expect(AgentProcessClassifier.agentKind(for: "/usr/local/bin/claude") == .claude)
        #expect(
            AgentProcessClassifier.agentKind(
                for: "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
            ) == .codex
        )
        #expect(
            AgentProcessClassifier.agentKind(
                for: "/usr/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
            ) == .claude
        )
        #expect(AgentProcessClassifier.agentKind(for: "/Applications/Codex.app/Contents/MacOS/Codex") == nil)
        #expect(
            AgentProcessClassifier.agentKind(
                for: "/bin/zsh -lc rg /opt/homebrew/lib/node_modules/@openai/codex/"
            ) == nil
        )
    }

    @Test("Codex snapshots retain the latest task identity")
    func codexSnapshotRetainsTurnBoundary() {
        let data = Data(
            """
            {"type":"event_msg","payload":{"type":"task_started","turn_id":"old","started_at":100}}
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"new","started_at":200}}
            """.utf8
        )
        let snapshot = CodexRolloutLifecycle.snapshot(in: data)
        #expect(snapshot.state == .finished)
        #expect(snapshot.turnID == "new")
        #expect(snapshot.taskStartedAt == Date(timeIntervalSince1970: 200))
    }

    @Test("Response previews preserve Markdown and useful length")
    func responsePreviewPreservesMarkdown() {
        let message = """
        ## Result

        - First item
        - Second item

        \(String(repeating: "x", count: 400))
        """
        let reduction = SessionReducer.reduce(
            existing: nil,
            request: BridgeRequest(
                token: "token",
                agent: .codex,
                event: HookEventPayload(
                    name: "Stop",
                    sessionID: "session",
                    cwd: "/tmp/project",
                    lastAssistantMessage: message
                ),
                terminal: TerminalContext(kind: .terminal)
            )
        )

        #expect(reduction.session.lastResponsePreview?.contains("## Result\n\n- First item") == true)
        #expect((reduction.session.lastResponsePreview?.count ?? 0) > 220)
    }
}
