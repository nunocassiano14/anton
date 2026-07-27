import Combine
import Foundation
import GilfoyleCore

struct SessionDiscoveryResult {
    let completedSessionIDs: [String]
    let exitedSessions: [AgentSession]
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Anton's definition of working is deliberately user-centric: from the
    /// moment a prompt is sent until that prompt has a completed response.
    /// Local rollouts can be quiet between tool events, so their temporary
    /// `idle` observation must never make an in-flight turn look finished.
    private var awaitingResponse: Set<String> = []
    /// A completed rollout can briefly remain the latest local event after a
    /// reply was delivered. Do not treat that old completion as the reply to
    /// the newly sent prompt until a new working boundary is observed.
    private var awaitingFreshTaskStart: Set<String> = []
    private var latestTaskTurnID: [String: String] = [:]
    private var replySentAt: [String: Date] = [:]

    var activeCount: Int {
        sessions.filter {
            $0.state == .working
                || $0.state == .needsApproval
                || $0.state == .hasQuestion
        }.count
    }

    var needsUserCount: Int {
        sessions.filter { $0.state.needsUser }.count
    }

    @discardableResult
    func ingest(
        _ request: BridgeRequest,
        replacingSessionID: String? = nil,
        now: Date = Date()
    ) -> SessionReduction {
        let id = "\(request.agent.rawValue):\(request.event.sessionID)"
        let exactSession = sessions.first(where: { $0.id == id })
        let requestedReplacement = exactSession == nil
            ? replacingSessionID.flatMap { replacementID in
                sessions.first(where: { $0.id == replacementID })
            }
            : nil
        let syntheticSession = exactSession == nil && requestedReplacement == nil
            ? sessions.first(where: {
                (
                    $0.agentSessionID.hasPrefix("process-")
                        || $0.agentSessionID.hasPrefix("launch-")
                )
                    && SessionTerminalAssociation.matches(
                        $0,
                        agent: request.agent,
                        agentSessionID: request.event.sessionID,
                        terminal: request.terminal
                    )
            })
            : nil
        let replacedSession = requestedReplacement ?? syntheticSession
        let existing = exactSession ?? replacedSession
        let reduction = SessionReducer.reduce(existing: existing, request: request, now: now)
        var session = reduction.session
        // Process-discovery and launcher entries are intentionally synthetic.
        // The first official lifecycle hook upgrades either in place rather
        // than creating a duplicate row for the same agent.
        if replacedSession != nil {
            session.id = id
            session.agentSessionID = request.event.sessionID
            sessions.removeAll(where: { $0.id == replacedSession?.id })
        }
        upsert(session)
        if session.state == .working {
            awaitingResponse.insert(session.id)
            if request.event.name == "UserPromptSubmit" {
                awaitingFreshTaskStart.insert(session.id)
                replySentAt[session.id] = now
            } else {
                // A tool event proves that the new turn has started even when
                // the local process scanner has not observed it yet.
                awaitingFreshTaskStart.remove(session.id)
            }
        } else if session.state == .finished || session.state == .error || session.state == .disconnected {
            awaitingResponse.remove(session.id)
            awaitingFreshTaskStart.remove(session.id)
            replySentAt.removeValue(forKey: session.id)
        }
        return SessionReduction(
            session: session,
            didCompleteMainTurn: reduction.didCompleteMainTurn,
            requiresInteractiveResponse: reduction.requiresInteractiveResponse
        )
    }

    /// Reconciles the low-level process scanner with the board. Reports
    /// genuine work → completed transitions separately from synthetic
    /// sessions whose processes vanished, so the app can close the latter's
    /// exact terminal route without announcing a false completion.
    @discardableResult
    func discover(
        _ processes: [DiscoveredAgentSession],
        now: Date = Date()
    ) -> SessionDiscoveryResult {
        let liveProcessIDs = Set(processes.map(\.processID))
        var completedSessionIDs: [String] = []
        for process in processes {
            if let index = sessions.firstIndex(where: {
                SessionTerminalAssociation.matches(
                    $0,
                    agent: process.agent,
                    agentSessionID: process.agentSessionID,
                    terminal: process.terminal
                )
            }) {
                let previous = sessions[index]
                let followsLocalAgentLifecycle = (process.agent == .codex || process.agent == .claude)
                    && ![.needsApproval, .hasQuestion, .error, .disconnected].contains(previous.state)
                let session: AgentSession
                let didComplete: Bool

                let shouldHoldWorking = previous.state == .working
                    && awaitingResponse.contains(previous.id)
                    && process.state == .idle

                let isPriorCompletionAfterReply = previous.state == .working
                    && awaitingResponse.contains(previous.id)
                    && awaitingFreshTaskStart.contains(previous.id)
                    && process.state == .finished
                    && !hasFreshTaskBoundary(process, sessionID: previous.id)

                if process.state == .working || hasFreshTaskBoundary(process, sessionID: previous.id) {
                    awaitingFreshTaskStart.remove(previous.id)
                }
                if let turnID = process.taskTurnID {
                    latestTaskTurnID[previous.id] = turnID
                }

                if shouldHoldWorking || isPriorCompletionAfterReply {
                    // The rollout has no fresh boundary yet. Preserve the
                    // visible working state until a completion event arrives.
                    var waiting = previous
                    waiting.sessionName = process.sessionName ?? previous.sessionName
                    waiting.model = process.model ?? previous.model
                    waiting.lastResponsePreview = process.lastResponsePreview ?? previous.lastResponsePreview
                    waiting.terminal = SessionTerminalAssociation.merged(
                        existing: previous.terminal,
                        incoming: process.terminal
                    )
                    waiting.updatedAt = now
                    sessions[index] = waiting
                    continue
                } else if previous.agentSessionID.hasPrefix("process-") || followsLocalAgentLifecycle {
                    let reduction = SessionDiscoveryReducer.reduce(
                        existing: previous,
                        cwd: process.cwd,
                        sessionName: process.sessionName,
                        model: process.model,
                        lastResponsePreview: process.lastResponsePreview,
                        observedActivity: process.activity,
                        state: process.state,
                        now: now
                    )
                    var reconciled = reduction.session
                    reconciled.terminal = SessionTerminalAssociation.merged(
                        existing: previous.terminal,
                        incoming: process.terminal
                    )
                    session = reconciled
                    didComplete = reduction.didCompleteMainTurn
                } else {
                    // Interactive hook states remain authoritative. Local
                    // metadata can still refresh labels without dismissing an
                    // approval or question that is waiting for the user.
                    var refreshed = previous
                    refreshed.cwd = process.cwd
                    refreshed.projectName = URL(fileURLWithPath: process.cwd).lastPathComponent
                    refreshed.sessionName = process.sessionName ?? previous.sessionName
                    refreshed.model = process.model ?? previous.model
                    refreshed.lastResponsePreview = process.lastResponsePreview ?? previous.lastResponsePreview
                    refreshed.currentActivity = process.activity ?? previous.currentActivity
                    refreshed.terminal = SessionTerminalAssociation.merged(
                        existing: previous.terminal,
                        incoming: process.terminal
                    )
                    refreshed.updatedAt = now
                    session = refreshed
                    didComplete = false
                }
                sessions[index] = session

                if didComplete {
                    awaitingResponse.remove(session.id)
                    awaitingFreshTaskStart.remove(session.id)
                    replySentAt.removeValue(forKey: session.id)
                    completedSessionIDs.append(session.id)
                }
                continue
            }
            var session = AgentSession(
                agent: process.agent,
                agentSessionID: "process-\(process.processID)",
                cwd: process.cwd,
                sessionName: process.sessionName,
                model: process.model,
                state: process.state,
                startedAt: now,
                terminal: process.terminal
            )
            session.lastResponsePreview = process.lastResponsePreview
            session.currentActivity = process.activity
                ?? SessionDiscoveryReducer.activity(for: process.state)
            upsert(session)
            if let turnID = process.taskTurnID {
                latestTaskTurnID[session.id] = turnID
            }
        }

        // Discovery is only a live fallback. If a process vanished before a
        // lifecycle hook could identify it, remove its synthetic row.
        let vanishedSyntheticSessions = sessions.filter { session in
            session.agentSessionID.hasPrefix("process-")
                && !liveProcessIDs.contains(session.terminal.processID ?? -1)
        }
        sessions.removeAll {
            $0.agentSessionID.hasPrefix("process-")
                && !liveProcessIDs.contains($0.terminal.processID ?? -1)
        }
        for session in vanishedSyntheticSessions {
            awaitingResponse.remove(session.id)
            awaitingFreshTaskStart.remove(session.id)
            latestTaskTurnID.removeValue(forKey: session.id)
            replySentAt.removeValue(forKey: session.id)
        }
        sortSessions()
        return SessionDiscoveryResult(
            completedSessionIDs: completedSessionIDs,
            exitedSessions: vanishedSyntheticSessions
        )
    }

    func enrich(sessionID: String, name: String? = nil, model: String? = nil) {
        update(sessionID: sessionID) {
            if let name, !name.isEmpty { $0.sessionName = name }
            if let model, !model.isEmpty { $0.model = model }
        }
    }

    func addProvisional(_ session: AgentSession) {
        upsert(session)
    }

    func updateLaunchTerminal(sessionID: String, terminal: TerminalContext) {
        update(sessionID: sessionID) {
            $0.terminal = terminal
            $0.currentActivity = "Connecting to agent"
            $0.updatedAt = Date()
        }
    }

    func updateLaunchProgress(sessionID: String, activity: String) {
        update(sessionID: sessionID) {
            $0.currentActivity = activity
            $0.updatedAt = Date()
        }
    }

    func markLaunchFailed(sessionID: String, message: String) {
        update(sessionID: sessionID) {
            $0.state = .error
            $0.currentActivity = message
            $0.updatedAt = Date()
        }
    }

    func markLaunchRetrying(sessionID: String) {
        update(sessionID: sessionID) {
            $0.state = .working
            $0.currentActivity = "Opening terminal"
            $0.updatedAt = Date()
        }
    }

    @discardableResult
    func markWorking(
        sessionID: String,
        activity: String = "Prompt sent",
        awaitingReply: Bool = true
    ) -> Bool {
        // UserPromptSubmit and local process discovery can beat the terminal
        // automation callback. In that case the authoritative activity is
        // already visible; never overwrite "Thinking", a live tool, or a
        // recovered completion with the weaker delivery acknowledgement.
        guard session(id: sessionID)?.state != .working else { return false }
        update(sessionID: sessionID) {
            $0.state = .working
            $0.currentActivity = activity
            $0.interaction = nil
            $0.updatedAt = Date()
        }
        if awaitingReply {
            awaitingResponse.insert(sessionID)
            awaitingFreshTaskStart.insert(sessionID)
            replySentAt[sessionID] = Date()
        }
        return true
    }

    func markPromptSubmissionUnconfirmed(
        sessionID: String,
        expectedActivity: String
    ) {
        guard
            let session = session(id: sessionID),
            session.state == .working,
            session.currentActivity == expectedActivity
        else {
            return
        }
        update(sessionID: sessionID) {
            $0.state = .error
            $0.currentActivity = "Prompt submission was not acknowledged"
            $0.updatedAt = Date()
        }
        awaitingResponse.remove(sessionID)
        awaitingFreshTaskStart.remove(sessionID)
        replySentAt.removeValue(forKey: sessionID)
    }

    func resolveInteraction(sessionID: String, nextState: AgentSessionState = .working) {
        update(sessionID: sessionID) {
            $0.interaction = nil
            $0.state = nextState
            $0.currentActivity = nextState == .working ? "Continuing" : $0.currentActivity
            $0.updatedAt = Date()
        }
        if nextState != .working {
            awaitingResponse.remove(sessionID)
            awaitingFreshTaskStart.remove(sessionID)
        }
    }

    func markDisconnected(sessionID: String, reason: String = "Agent process exited") {
        update(sessionID: sessionID) {
            $0.interaction = nil
            $0.state = .disconnected
            $0.currentActivity = reason
            $0.updatedAt = Date()
        }
    }

    func dismiss(sessionID: String) {
        sessions.removeAll(where: { $0.id == sessionID })
        awaitingResponse.remove(sessionID)
        awaitingFreshTaskStart.remove(sessionID)
        latestTaskTurnID.removeValue(forKey: sessionID)
        replySentAt.removeValue(forKey: sessionID)
    }

    func session(id: String) -> AgentSession? {
        sessions.first(where: { $0.id == id })
    }

    private func update(sessionID: String, mutate: (inout AgentSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var value = sessions[index]
        mutate(&value)
        sessions[index] = value
        sortSessions()
    }

    private func upsert(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sortSessions()
    }

    private func sortSessions() {
        sessions.sort { lhs, rhs in
            let lhsPriority = priority(lhs.state)
            let rhsPriority = priority(rhs.state)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func priority(_ state: AgentSessionState) -> Int {
        switch state {
        // The board is action-first: an approval is the most time-sensitive,
        // then a question, followed by failures that need attention.
        case .needsApproval: return 0
        case .hasQuestion: return 1
        case .error: return 2
        case .working: return 3
        case .finished: return 4
        case .idle: return 5
        case .disconnected: return 6
        }
    }

    private func hasFreshTaskBoundary(
        _ process: DiscoveredAgentSession,
        sessionID: String
    ) -> Bool {
        if let turnID = process.taskTurnID,
           let previousTurnID = latestTaskTurnID[sessionID] {
            return turnID != previousTurnID
        }
        guard let taskStartedAt = process.taskStartedAt,
              let sentAt = replySentAt[sessionID]
        else {
            return process.state == .working
        }
        // Codex timestamps task starts to whole seconds. Allow for that
        // precision while still rejecting the old completed turn.
        return taskStartedAt >= sentAt.addingTimeInterval(-1)
    }
}
