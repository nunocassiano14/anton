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

    /// Submits text that is already present in the target agent's composer.
    /// Concrete terminal adapters can implement this without focusing the tab.
    func submit(
        session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    )

    /// Closes only the terminal surface identified by the session's stable
    /// route. Implementations must never fall back to the selected tab.
    func close(
        session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

public protocol TerminalSessionLaunching {
    func launch(
        plan: AgentSessionLaunchPlan,
        completion: @escaping (Result<TerminalContext, Error>) -> Void
    )
}

public extension TerminalSessionControlling {
    func submit(
        session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        send(text: "", to: session, completion: completion)
    }

    func close(
        session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        completion(.failure(TerminalRouteError.unsupportedClose))
    }
}

public enum TerminalRouteError: LocalizedError, Equatable {
    case missingStableIdentifier
    case unsupportedClose

    public var errorDescription: String? {
        switch self {
        case .missingStableIdentifier:
            return "This terminal session does not expose a stable target identifier."
        case .unsupportedClose:
            return "This terminal adapter cannot close the ended session."
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
