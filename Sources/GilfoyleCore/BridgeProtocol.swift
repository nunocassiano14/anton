import Foundation

public let antonProtocolVersion = 1

public enum BridgeDecisionKind: String, Codable, Sendable {
    case acknowledge
    case allow
    case deny
    case answer
    case cancel
}

public struct BridgeRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var token: String
    public var requestID: String
    public var agent: AgentKind
    public var event: HookEventPayload
    public var terminal: TerminalContext
    public var sentAt: Date

    public init(
        token: String,
        requestID: String = UUID().uuidString,
        agent: AgentKind,
        event: HookEventPayload,
        terminal: TerminalContext,
        sentAt: Date = Date()
    ) {
        self.protocolVersion = antonProtocolVersion
        self.token = token
        self.requestID = requestID
        self.agent = agent
        self.event = event
        self.terminal = terminal
        self.sentAt = sentAt
    }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var requestID: String
    public var decision: BridgeDecisionKind
    public var message: String?
    public var payload: JSONValue?

    public init(
        requestID: String,
        decision: BridgeDecisionKind,
        message: String? = nil,
        payload: JSONValue? = nil
    ) {
        self.protocolVersion = antonProtocolVersion
        self.requestID = requestID
        self.decision = decision
        self.message = message
        self.payload = payload
    }
}

public enum AntonPaths {
    public static func applicationSupport(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Anton", isDirectory: true)
    }

    public static func socketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        applicationSupport(home: home).appendingPathComponent("bridge.sock")
    }

    public static func tokenURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        applicationSupport(home: home).appendingPathComponent("ipc-token")
    }

    public static func backupsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        applicationSupport(home: home).appendingPathComponent("Backups", isDirectory: true)
    }
}
