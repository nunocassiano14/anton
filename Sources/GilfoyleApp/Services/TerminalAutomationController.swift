import AppKit
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
        // Terminal.app brings itself forward as a side effect of `do script`,
        // even when the AppleScript contains no explicit `activate`. Remember
        // the user's current app so a background reply can restore it before
        // Anton reports that delivery has completed.
        let foregroundApplication = action == .send
            ? NSWorkspace.shared.frontmostApplication
            : nil

        func finish(_ result: Result<Void, Error>) {
            DispatchQueue.main.async {
                if action == .send,
                   let foregroundApplication,
                   !foregroundApplication.isTerminated
                {
                    foregroundApplication.activate()
                }
                completion(result)
            }
        }

        queue.async {
            do {
                let result: String
                switch try TerminalRouteResolver.resolve(session.terminal) {
                case .terminal(let tty):
                    if action == .send {
                        result = try self.runAppleScript(
                            TerminalAutomationScripts.terminalSend,
                            arguments: [tty, text ?? ""]
                        )
                    } else {
                        result = try self.runAppleScript(
                            TerminalAutomationScripts.terminalFocus,
                            arguments: [tty]
                        )
                    }
                case .iTerm(let identifier, let tty):
                    if action == .send {
                        result = try self.runAppleScript(
                            TerminalAutomationScripts.iTermSend,
                            arguments: [identifier ?? "", tty ?? "", text ?? ""]
                        )
                    } else {
                        result = try self.runAppleScript(
                            TerminalAutomationScripts.iTermFocus,
                            arguments: [identifier ?? "", tty ?? ""]
                        )
                    }
                }

                guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
                    throw TerminalAutomationError.targetNotFound
                }
                finish(.success(()))
            } catch {
                finish(.failure(error))
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

}
