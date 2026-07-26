import Darwin
import Foundation
import Testing
@testable import GilfoyleCore

@Suite("Agent session termination")
struct AgentSessionTerminatorTests {
    @Test("Graceful termination targets only the validated PID")
    func gracefulTerminationUsesSIGTERM() throws {
        let process = FakeAgentProcessOperator(
            snapshot: snapshot(agent: .codex)
        )
        try AgentSessionTerminator(
            processOperator: process,
            pollMilliseconds: 0
        ).terminate(session(agent: .codex))

        #expect(process.signals == [SIGTERM])
    }

    @Test("A stale PID belonging to another process is never signalled")
    func stalePIDIsRejected() {
        let process = FakeAgentProcessOperator(
            snapshot: AgentProcessSnapshot(
                processID: 4_242,
                tty: "ttys009",
                arguments: "/usr/bin/python3 worker.py"
            )
        )

        #expect(throws: AgentSessionTerminationError.agentMismatch) {
            try AgentSessionTerminator(
                processOperator: process,
                pollMilliseconds: 0
            ).terminate(session(agent: .codex))
        }
        #expect(process.signals.isEmpty)
    }

    @Test("A process on another TTY is never signalled")
    func wrongTTYIsRejected() {
        let process = FakeAgentProcessOperator(
            snapshot: AgentProcessSnapshot(
                processID: 4_242,
                tty: "ttys010",
                arguments: "/opt/homebrew/bin/codex --yolo"
            )
        )

        #expect(throws: AgentSessionTerminationError.terminalMismatch) {
            try AgentSessionTerminator(
                processOperator: process,
                pollMilliseconds: 0
            ).terminate(session(agent: .codex))
        }
        #expect(process.signals.isEmpty)
    }

    @Test("A stubborn validated agent escalates to SIGKILL")
    func stubbornProcessEscalates() throws {
        let process = FakeAgentProcessOperator(
            snapshot: snapshot(agent: .claude),
            exitsOnSIGTERM: false
        )
        try AgentSessionTerminator(
            processOperator: process,
            gracefulPollCount: 1,
            forcedPollCount: 1,
            pollMilliseconds: 0
        ).terminate(session(agent: .claude))

        #expect(process.signals == [SIGTERM, SIGKILL])
    }

    @Test("A reused PID is revalidated and the replacement is not killed")
    func reusedPIDIsNotKilled() throws {
        let replacement = AgentProcessSnapshot(
            processID: 4_242,
            tty: "ttys009",
            arguments: "/usr/bin/python3 replacement.py"
        )
        let process = FakeAgentProcessOperator(
            snapshot: snapshot(agent: .codex),
            exitsOnSIGTERM: false,
            replacementAfterWait: replacement
        )
        try AgentSessionTerminator(
            processOperator: process,
            gracefulPollCount: 1,
            forcedPollCount: 1,
            pollMilliseconds: 0
        ).terminate(session(agent: .codex))

        #expect(process.signals == [SIGTERM])
        #expect(process.currentSnapshot == replacement)
    }

    private func session(agent: AgentKind) -> AgentSession {
        AgentSession(
            agent: agent,
            agentSessionID: "termination-test",
            cwd: "/tmp/anton",
            state: .working,
            terminal: TerminalContext(
                kind: .terminal,
                tty: "/dev/ttys009",
                processID: 4_242
            )
        )
    }

    private func snapshot(agent: AgentKind) -> AgentProcessSnapshot {
        AgentProcessSnapshot(
            processID: 4_242,
            tty: "ttys009",
            arguments: agent == .codex
                ? "/opt/homebrew/bin/codex --yolo"
                : "/usr/local/bin/claude"
        )
    }
}

private final class FakeAgentProcessOperator: AgentProcessOperating, @unchecked Sendable {
    private(set) var currentSnapshot: AgentProcessSnapshot?
    private(set) var signals: [Int32] = []
    private let exitsOnSIGTERM: Bool
    private let replacementAfterWait: AgentProcessSnapshot?
    private var hasWaited = false

    init(
        snapshot: AgentProcessSnapshot,
        exitsOnSIGTERM: Bool = true,
        replacementAfterWait: AgentProcessSnapshot? = nil
    ) {
        self.currentSnapshot = snapshot
        self.exitsOnSIGTERM = exitsOnSIGTERM
        self.replacementAfterWait = replacementAfterWait
    }

    func snapshot(processID: Int32) -> AgentProcessSnapshot? {
        currentSnapshot?.processID == processID ? currentSnapshot : nil
    }

    func send(signal: Int32, to processID: Int32) -> Bool {
        guard currentSnapshot?.processID == processID else { return false }
        signals.append(signal)
        if signal == SIGKILL || (signal == SIGTERM && exitsOnSIGTERM) {
            currentSnapshot = nil
        }
        return true
    }

    func wait(milliseconds: UInt32) {
        if !hasWaited, let replacementAfterWait {
            currentSnapshot = replacementAfterWait
        }
        hasWaited = true
    }
}
