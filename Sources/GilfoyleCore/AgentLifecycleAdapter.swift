import Foundation

public protocol AgentLifecycleAdapting {
    var agent: AgentKind { get }

    func decode(
        data: Data,
        terminal: TerminalContext,
        token: String
    ) throws -> BridgeRequest

    func render(
        request: BridgeRequest,
        response: BridgeResponse
    ) throws -> Data?
}

public extension AgentLifecycleAdapting {
    func decode(
        data: Data,
        terminal: TerminalContext,
        token: String
    ) throws -> BridgeRequest {
        try HookInputParser.parse(
            data: data,
            agent: agent,
            terminal: terminal,
            token: token
        )
    }

    func render(
        request: BridgeRequest,
        response: BridgeResponse
    ) throws -> Data? {
        try HookResponseRenderer.render(request: request, response: response)
    }
}

public struct ClaudeLifecycleAdapter: AgentLifecycleAdapting {
    public let agent = AgentKind.claude

    public init() {}

    public func decode(
        data: Data,
        terminal: TerminalContext,
        token: String
    ) throws -> BridgeRequest {
        var request = try HookInputParser.parse(
            data: data,
            agent: agent,
            terminal: terminal,
            token: token
        )
        guard
            request.event.name == "Stop" || request.event.name == "StopFailure",
            request.event.lastAssistantMessage == nil,
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let transcriptPath = raw["transcript_path"] as? String,
            let transcript = boundedTail(atPath: transcriptPath)
        else {
            return request
        }

        // Recent Claude Code releases may omit `last_assistant_message` from
        // Stop while still providing the local transcript path. Resolve the
        // final reply inside the short-lived helper and forward only the
        // bounded response preview—not the path or the transcript itself.
        request.event.lastAssistantMessage = LocalAgentResponsePreview.claude(in: transcript)
        return request
    }

    private func boundedTail(atPath path: String) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: length > 524_288 ? length - 524_288 : 0)
        return handle.readDataToEndOfFile()
    }
}

public struct CodexLifecycleAdapter: AgentLifecycleAdapting {
    public let agent = AgentKind.codex

    public init() {}
}

public enum AgentLifecycleAdapters {
    public static func adapter(for agent: AgentKind) -> any AgentLifecycleAdapting {
        switch agent {
        case .claude:
            return ClaudeLifecycleAdapter()
        case .codex:
            return CodexLifecycleAdapter()
        }
    }
}
