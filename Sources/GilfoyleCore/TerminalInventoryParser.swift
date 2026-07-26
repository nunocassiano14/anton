import Foundation

public struct ParsedITermSession: Equatable, Sendable {
    public let identifier: String
    public let title: String?

    public init(identifier: String, title: String?) {
        self.identifier = identifier
        self.title = title
    }
}

public struct ParsedTerminalInventory: Equatable, Sendable {
    public let terminalTitles: [String: String]
    public let iTermSessions: [String: ParsedITermSession]

    public init(
        terminalTitles: [String: String],
        iTermSessions: [String: ParsedITermSession]
    ) {
        self.terminalTitles = terminalTitles
        self.iTermSessions = iTermSessions
    }
}

/// Converts the line-delimited AppleScript inventory into stable TTY maps.
/// Split panes and restored tabs can briefly report the same TTY; the latest
/// valid row wins instead of relying on Dictionary's unique-key precondition.
public enum TerminalInventoryParser {
    public static func parse(
        terminalLines: [String],
        iTermLines: [String]
    ) -> ParsedTerminalInventory {
        let terminalTitles = terminalLines.reduce(into: [String: String]()) {
            result,
            value in
            let parts = value.split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { return }
            result[parts[0]] = parts[1]
        }

        let iTermSessions = iTermLines.reduce(into: [String: ParsedITermSession]()) {
            result,
            value in
            let parts = value.split(
                separator: "|",
                maxSplits: 2,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                return
            }
            result[parts[0]] = ParsedITermSession(
                identifier: parts[1],
                title: parts.count == 3 && !parts[2].isEmpty ? parts[2] : nil
            )
        }

        return ParsedTerminalInventory(
            terminalTitles: terminalTitles,
            iTermSessions: iTermSessions
        )
    }
}
