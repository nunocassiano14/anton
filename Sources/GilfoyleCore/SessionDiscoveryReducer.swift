import Foundation

/// Applies a fresh local process observation to Anton's synthetic session.
/// Keeping this reducer pure makes the no-hook completion fallback testable.
public enum SessionDiscoveryReducer {
    public static func reduce(
        existing: AgentSession,
        cwd: String,
        sessionName: String?,
        model: String?,
        lastResponsePreview: String? = nil,
        state: AgentSessionState,
        now: Date = Date()
    ) -> (session: AgentSession, didCompleteMainTurn: Bool) {
        var session = existing
        let didComplete = existing.state == .working && state == .finished
        session.cwd = cwd
        session.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        session.sessionName = sessionName ?? existing.sessionName
        session.model = model ?? existing.model
        session.lastResponsePreview = lastResponsePreview ?? existing.lastResponsePreview
        session.state = state
        session.currentActivity = activity(for: state)
        session.updatedAt = now
        if didComplete { session.completedAt = now }
        return (session, didComplete)
    }

    public static func activity(for state: AgentSessionState) -> String {
        switch state {
        case .working: return "Working · live session activity"
        case .finished: return "Response ready"
        case .idle: return "Open session · awaiting next hook"
        case .disconnected: return "Session disconnected"
        case .needsApproval, .hasQuestion, .error: return "Open session · awaiting next hook"
        }
    }
}
