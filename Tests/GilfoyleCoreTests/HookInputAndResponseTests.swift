import Foundation
import Testing
@testable import GilfoyleCore

@Suite("Hook input and output")
struct HookInputAndResponseTests {
    @Test("Prompts and transcript paths are not forwarded")
    func parserDoesNotForwardPromptOrTranscript() throws {
        let raw: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session",
            "cwd": "/tmp/project",
            "prompt": "TOP SECRET USER PROMPT",
            "transcript_path": "/tmp/private-transcript.jsonl",
            "model": "gpt-test"
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let request = try HookInputParser.parse(
            data: data,
            agent: .codex,
            terminal: TerminalContext(kind: .iTerm),
            token: "token"
        )

        let encoded = try JSONEncoder().encode(request)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("TOP SECRET"))
        #expect(!text.contains("private-transcript"))
        #expect(request.event.toolInput == nil)
    }

    @Test("Current approval input is retained")
    func parserKeepsOnlyCurrentApprovalInput() throws {
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
        let request = try HookInputParser.parse(
            data: JSONSerialization.data(withJSONObject: raw),
            agent: .codex,
            terminal: TerminalContext(kind: .terminal),
            token: "token"
        )
        #expect(request.event.toolInput?["command"]?.stringValue == "swift test")
    }

    @Test("Claude approval output allows through official hook schema")
    func claudeApprovalAllowOutput() throws {
        let request = makeRequest(agent: .claude, event: "PermissionRequest", toolName: "Bash")
        let rendered = try HookResponseRenderer.render(
            request: request,
            response: BridgeResponse(requestID: request.requestID, decision: .allow)
        )
        let data = try #require(rendered)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(output["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
    }

    @Test("Claude Stop recovers an omitted response from its local transcript")
    func claudeStopRecoversResponseFromTranscript() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntonClaudeStop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("session.jsonl")
        let transcriptData = Data(
            """
            {"type":"user","uuid":"turn","timestamp":"2026-07-26T20:32:41.642Z","message":{"role":"user","content":"private prompt"}}
            {"type":"assistant","uuid":"reply","timestamp":"2026-07-26T20:32:50.946Z","message":{"role":"assistant","content":[{"type":"text","text":"Recovered Claude response"}]}}
            """.utf8
        )
        try transcriptData.write(to: transcript)
        let input = try JSONSerialization.data(
            withJSONObject: [
                "hook_event_name": "Stop",
                "session_id": "session",
                "cwd": "/tmp/project",
                "transcript_path": transcript.path
            ]
        )

        let request = try ClaudeLifecycleAdapter().decode(
            data: input,
            terminal: TerminalContext(kind: .terminal),
            token: "token"
        )
        #expect(request.event.lastAssistantMessage == "Recovered Claude response")
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains(transcript.path))
        #expect(!encoded.contains("private prompt"))
    }

    @Test("Claude question answers are injected into updatedInput")
    func claudeQuestionInjectsAnswersIntoUpdatedInput() throws {
        let request = makeRequest(
            agent: .claude,
            event: "PreToolUse",
            toolName: "AskUserQuestion",
            toolInput: .object([
                "questions": .array([
                    .object(["question": .string("Which framework?")])
                ])
            ])
        )
        let response = BridgeResponse(
            requestID: request.requestID,
            decision: .answer,
            payload: .object([
                "answers": .object(["Which framework?": .string("SwiftUI")])
            ])
        )
        let rendered = try HookResponseRenderer.render(request: request, response: response)
        let data = try #require(rendered)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        let updated = try #require(specific["updatedInput"] as? [String: Any])
        let answers = try #require(updated["answers"] as? [String: String])
        #expect(answers["Which framework?"] == "SwiftUI")
    }

    @Test("Codex question answer is delivered as model feedback")
    func codexQuestionReturnsAnswerAsModelFeedback() throws {
        let request = makeRequest(
            agent: .codex,
            event: "PreToolUse",
            toolName: "request_user_input",
            toolInput: .object(["questions": .array([])])
        )
        let response = BridgeResponse(
            requestID: request.requestID,
            decision: .answer,
            payload: .object(["answers": .object(["framework": .string("SwiftUI")])])
        )
        let rendered = try HookResponseRenderer.render(request: request, response: response)
        let data = try #require(rendered)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["decision"] as? String == "block")
        #expect((root["reason"] as? String)?.contains("SwiftUI") == true)
    }

    @Test("Codex Stop acknowledges with valid neutral JSON")
    func codexStopReturnsNeutralJSON() throws {
        let request = makeRequest(agent: .codex, event: "Stop", toolName: nil)
        let rendered = try HookResponseRenderer.render(
            request: request,
            response: BridgeResponse(requestID: request.requestID, decision: .acknowledge)
        )
        let data = try #require(rendered)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root.isEmpty)
    }

    private func makeRequest(
        agent: AgentKind,
        event: String,
        toolName: String?,
        toolInput: JSONValue? = nil
    ) -> BridgeRequest {
        BridgeRequest(
            token: "token",
            agent: agent,
            event: HookEventPayload(
                name: event,
                sessionID: "session",
                cwd: "/tmp/project",
                toolName: toolName,
                toolInput: toolInput
            ),
            terminal: TerminalContext(kind: .terminal)
        )
    }
}
