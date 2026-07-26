import Foundation

/// Extracts the current Codex task boundary from a bounded local rollout
/// fragment. This intentionally reads event type only: prompts, responses and
/// tool input are neither required nor retained.
public enum CodexRolloutLifecycle {
    public static func state(in data: Data) -> AgentSessionState {
        guard let text = String(data: data, encoding: .utf8) else { return .idle }

        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }

            if type == "task_complete" { return .finished }
            if type == "task_started" { return .working }
        }
        return .idle
    }
}
