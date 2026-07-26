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
