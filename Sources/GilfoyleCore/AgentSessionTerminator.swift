import Darwin
import Foundation

public struct AgentProcessSnapshot: Equatable, Sendable {
    public let processID: Int32
    public let tty: String
    public let arguments: String

    public init(processID: Int32, tty: String, arguments: String) {
        self.processID = processID
        self.tty = tty
        self.arguments = arguments
    }
}

public enum AgentSessionTerminationError: Error, Equatable, LocalizedError {
    case missingProcessIdentity
    case processNotRunning
    case agentMismatch
    case terminalMismatch
    case signalFailed
    case processRefusedToExit

    public var errorDescription: String? {
        switch self {
        case .missingProcessIdentity:
            return "Anton cannot safely identify this agent process."
        case .processNotRunning:
            return "This agent process is no longer running."
        case .agentMismatch:
            return "The process ID now belongs to a different application, so Anton did not end it."
        case .terminalMismatch:
            return "The process moved to a different terminal session, so Anton did not end it."
        case .signalFailed:
            return "macOS refused the request to end this agent session."
        case .processRefusedToExit:
            return "The agent did not exit after Anton asked it to stop."
        }
    }
}

public protocol AgentProcessOperating: Sendable {
    func snapshot(processID: Int32) -> AgentProcessSnapshot?
    func send(signal: Int32, to processID: Int32) -> Bool
    func wait(milliseconds: UInt32)
}

public struct SystemAgentProcessOperator: AgentProcessOperating {
    public init() {}

    public func snapshot(processID: Int32) -> AgentProcessSnapshot? {
        guard processID > 1, Darwin.kill(processID, 0) == 0 || errno == EPERM else {
            return nil
        }
        let output = Self.processOutput(
            arguments: [
                "-p", String(processID),
                "-o", "tty=",
                "-o", "args="
            ]
        )
        guard let line = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else {
            return nil
        }
        let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2 else { return nil }
        return AgentProcessSnapshot(
            processID: processID,
            tty: String(fields[0]),
            arguments: String(fields[1])
        )
    }

    public func send(signal: Int32, to processID: Int32) -> Bool {
        Darwin.kill(processID, signal) == 0
    }

    public func wait(milliseconds: UInt32) {
        usleep(milliseconds * 1_000)
    }

    private static func processOutput(arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

public protocol AgentSessionTerminating: Sendable {
    func terminate(_ session: AgentSession) throws
}

/// Ends only the exact process Anton originally associated with a session.
/// PID reuse is guarded by re-checking both the supported agent executable and
/// its terminal TTY before SIGTERM and again before a SIGKILL fallback.
public struct AgentSessionTerminator: AgentSessionTerminating {
    private let processOperator: any AgentProcessOperating
    private let gracefulPollCount: Int
    private let forcedPollCount: Int
    private let pollMilliseconds: UInt32

    public init(
        processOperator: any AgentProcessOperating = SystemAgentProcessOperator(),
        gracefulPollCount: Int = 20,
        forcedPollCount: Int = 10,
        pollMilliseconds: UInt32 = 100
    ) {
        self.processOperator = processOperator
        self.gracefulPollCount = gracefulPollCount
        self.forcedPollCount = forcedPollCount
        self.pollMilliseconds = pollMilliseconds
    }

    public func terminate(_ session: AgentSession) throws {
        guard let processID = session.terminal.processID, processID > 1 else {
            throw AgentSessionTerminationError.missingProcessIdentity
        }
        guard let initial = processOperator.snapshot(processID: processID) else {
            throw AgentSessionTerminationError.processNotRunning
        }
        try Self.validate(snapshot: initial, for: session)
        guard processOperator.send(signal: SIGTERM, to: processID) else {
            throw AgentSessionTerminationError.signalFailed
        }
        if waitForExit(of: session, processID: processID, attempts: gracefulPollCount) {
            return
        }

        // A PID can be reused after the first process exits. Only force-kill
        // when the current snapshot still belongs to this exact agent + TTY.
        guard let current = processOperator.snapshot(processID: processID) else { return }
        do {
            try Self.validate(snapshot: current, for: session)
        } catch {
            // The original session is gone; never signal the replacement.
            return
        }
        guard processOperator.send(signal: SIGKILL, to: processID) else {
            throw AgentSessionTerminationError.signalFailed
        }
        guard waitForExit(of: session, processID: processID, attempts: forcedPollCount) else {
            throw AgentSessionTerminationError.processRefusedToExit
        }
    }

    public static func validate(
        snapshot: AgentProcessSnapshot,
        for session: AgentSession
    ) throws {
        guard snapshot.processID == session.terminal.processID else {
            throw AgentSessionTerminationError.missingProcessIdentity
        }
        guard AgentProcessClassifier.agentKind(for: snapshot.arguments) == session.agent else {
            throw AgentSessionTerminationError.agentMismatch
        }
        if let expectedTTY = normalizedTTY(session.terminal.tty) {
            guard normalizedTTY(snapshot.tty) == expectedTTY else {
                throw AgentSessionTerminationError.terminalMismatch
            }
        }
    }

    private func waitForExit(
        of session: AgentSession,
        processID: Int32,
        attempts: Int
    ) -> Bool {
        for _ in 0..<attempts {
            processOperator.wait(milliseconds: pollMilliseconds)
            guard let current = processOperator.snapshot(processID: processID) else {
                return true
            }
            do {
                try Self.validate(snapshot: current, for: session)
            } catch {
                // The PID no longer describes the target session.
                return true
            }
        }
        return false
    }

    private static func normalizedTTY(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??", trimmed != "-" else { return nil }
        return trimmed.hasPrefix("/dev/") ? trimmed : "/dev/\(trimmed)"
    }
}
