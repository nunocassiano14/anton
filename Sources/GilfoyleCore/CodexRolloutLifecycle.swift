import Foundation

public struct CodexRolloutSnapshot: Equatable, Sendable {
    public let state: AgentSessionState
    public let turnID: String?
    public let taskStartedAt: Date?

    public init(
        state: AgentSessionState,
        turnID: String? = nil,
        taskStartedAt: Date? = nil
    ) {
        self.state = state
        self.turnID = turnID
        self.taskStartedAt = taskStartedAt
    }
}

/// Extracts the current Codex task boundary from a bounded local rollout
/// fragment. This intentionally reads event type only: prompts, responses and
/// tool input are neither required nor retained.
public enum CodexRolloutLifecycle {
    public static func state(in data: Data) -> AgentSessionState {
        snapshot(in: data).state
    }

    public static func snapshot(in data: Data) -> CodexRolloutSnapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            return CodexRolloutSnapshot(state: .idle)
        }

        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }

            let state: AgentSessionState
            if type == "task_complete" {
                state = .finished
            } else if type == "task_started" {
                state = .working
            } else {
                continue
            }
            let startedAt = (payload["started_at"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            return CodexRolloutSnapshot(
                state: state,
                turnID: payload["turn_id"] as? String,
                taskStartedAt: startedAt
            )
        }
        return CodexRolloutSnapshot(state: .idle)
    }
}
