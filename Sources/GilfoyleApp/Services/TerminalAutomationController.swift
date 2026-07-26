import Foundation
import GilfoyleCore

enum TerminalAutomationError: LocalizedError {
    case missingIdentifier
    case targetNotFound
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingIdentifier:
            return "This terminal session does not expose a stable target identifier."
        case .targetNotFound:
            return "The original terminal tab could not be found."
        case .scriptFailed(let message):
            return message
        }
    }
}

final class TerminalAutomationController: TerminalSessionControlling {
    private let queue = DispatchQueue(label: "com.augustalabs.anton.terminal-automation")

    func focus(session: AgentSession, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(action: .focus, session: session, text: nil, completion: completion)
    }

    func send(
        text: String,
        to session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        perform(action: .send, session: session, text: text, completion: completion)
    }

    private enum Action {
        case focus
        case send
    }

    private func perform(
        action: Action,
        session: AgentSession,
        text: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            do {
                let result: String
                switch try TerminalRouteResolver.resolve(session.terminal) {
                case .terminal(let tty):
                    result = try self.runAppleScript(
                        Self.terminalScript,
                        arguments: [tty, action == .send ? "send" : "focus", text ?? ""]
                    )
                case .iTerm(let identifier, let tty):
                    result = try self.runAppleScript(
                        Self.iTermScript,
                        arguments: [
                            identifier ?? "",
                            tty ?? "",
                            action == .send ? "send" : "focus",
                            text ?? ""
                        ]
                    )
                }

                guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
                    throw TerminalAutomationError.targetNotFound
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func runAppleScript(_ source: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source, "--"] + arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let timeout = Date().addingTimeInterval(30)
        while process.isRunning && Date() < timeout {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw TerminalAutomationError.scriptFailed(
                "Terminal automation timed out. Your draft is still available in Anton."
            )
        }

        let errorText = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw TerminalAutomationError.scriptFailed(
                errorText.isEmpty ? "Terminal automation failed." : errorText
            )
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private static let terminalScript = """
    on run argv
        set targetTTY to item 1 of argv
        set requestedAction to item 2 of argv
        set promptText to item 3 of argv
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is targetTTY then
                        if requestedAction is "send" then
                            -- `do script` supplies one Return. Interactive
                            -- TUIs can consume that first Return to finish a
                            -- paste, so send a second empty native command.
                            -- This avoids System Events keystrokes and their
                            -- separate Accessibility permission.
                            set selected of terminalTab to true
                            set index of terminalWindow to 1
                            activate
                            do script promptText in terminalTab
                            delay 0.12
                            do script "" in terminalTab
                            return "ok"
                        end if
                        set selected of terminalTab to true
                        set index of terminalWindow to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    private static let iTermScript = """
    on run argv
        set targetIdentifier to item 1 of argv
        set targetTTY to item 2 of argv
        set requestedAction to item 3 of argv
        set promptText to item 4 of argv
        if targetIdentifier contains ":" then
            set AppleScript's text item delimiters to ":"
            set identifierParts to text items of targetIdentifier
            set targetIdentifier to last item of identifierParts
            set AppleScript's text item delimiters to ""
        end if
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        set sessionIdentifier to unique ID of terminalSession
                        set sessionTTY to tty of terminalSession
                        if (targetIdentifier is not "" and sessionIdentifier is targetIdentifier) or (targetTTY is not "" and sessionTTY is targetTTY) then
                            if requestedAction is "send" then
                                write terminalSession text promptText newline yes
                                return "ok"
                            end if
                            select terminalSession
                            select terminalTab
                            select terminalWindow
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """
}
