import Foundation

public protocol TerminalSessionControlling {
    func focus(
        session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    )

    func send(
        text: String,
        to session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

public enum TerminalRouteError: LocalizedError, Equatable {
    case missingStableIdentifier

    public var errorDescription: String? {
        switch self {
        case .missingStableIdentifier:
            return "This terminal session does not expose a stable target identifier."
        }
    }
}

public enum TerminalSessionRoute: Equatable, Sendable {
    case terminal(tty: String)
    case iTerm(uniqueID: String?, tty: String?)
}

public enum TerminalRouteResolver {
    public static func resolve(_ context: TerminalContext) throws -> TerminalSessionRoute {
        switch context.kind {
        case .terminal:
            guard let tty = nonEmpty(context.tty) else {
                throw TerminalRouteError.missingStableIdentifier
            }
            return .terminal(tty: tty)

        case .iTerm:
            let identifier = normalizedITermIdentifier(context.iTermSessionID)
            let tty = nonEmpty(context.tty)
            guard identifier != nil || tty != nil else {
                throw TerminalRouteError.missingStableIdentifier
            }
            return .iTerm(uniqueID: identifier, tty: tty)

        case .unknown:
            throw TerminalRouteError.missingStableIdentifier
        }
    }

    public static func normalizedITermIdentifier(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        return value.split(separator: ":").last.map(String.init)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
