import Foundation

/// Extracts only the latest locally stored agent reply needed for Anton's
/// visual callout. It never retains a transcript and limits the result to a
/// compact preview.
public enum LocalAgentResponsePreview {
    public static func codex(in data: Data) -> String? {
        for object in jsonLines(data).reversed() {
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            if let message = payload["last_agent_message"] as? String,
               let preview = normalized(message) { return preview }
            if let message = payload["message"] as? String,
               let preview = normalized(message) { return preview }
        }
        return nil
    }

    public static func claude(in data: Data) -> String? {
        for object in jsonLines(data).reversed() where object["type"] as? String == "assistant" {
            guard let message = object["message"] as? [String: Any] else { continue }
            if let content = message["content"] as? String,
               let preview = normalized(content) { return preview }
            if let content = message["content"] as? [[String: Any]] {
                let text = content.compactMap { item -> String? in
                    item["type"] as? String == "text" ? item["text"] as? String : nil
                }.joined(separator: "\n")
                if let preview = normalized(text) { return preview }
            }
        }
        return nil
    }

    private static func jsonLines(_ data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private static func normalized(_ value: String) -> String? {
        let formatted = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(
                of: #"\n(?:[ \t]*\n){2,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? nil : String(formatted.prefix(8_000))
    }
}

public struct ClaudeTranscriptSnapshot: Equatable, Sendable {
    public let lastUserTurnID: String?
    public let lastUserAt: Date?
    public let lastAssistantAt: Date?
    public let hasCompletedLatestTurn: Bool

    public init(
        lastUserTurnID: String?,
        lastUserAt: Date?,
        lastAssistantAt: Date?,
        hasCompletedLatestTurn: Bool
    ) {
        self.lastUserTurnID = lastUserTurnID
        self.lastUserAt = lastUserAt
        self.lastAssistantAt = lastAssistantAt
        self.hasCompletedLatestTurn = hasCompletedLatestTurn
    }
}

/// Claude's live session index exposes only `busy`/`idle`. The transcript
/// provides the missing turn boundary that lets Anton distinguish a genuinely
/// completed response from an old idle snapshot after a new prompt.
public enum ClaudeTranscriptLifecycle {
    public static func snapshot(in data: Data) -> ClaudeTranscriptSnapshot {
        var lastUserTurnID: String?
        var lastUserAt: Date?
        var lastAssistantAt: Date?

        for object in jsonLines(data) {
            guard let type = object["type"] as? String else { continue }
            if type == "user" {
                lastUserTurnID = object["uuid"] as? String ?? lastUserTurnID
                lastUserAt = timestamp(in: object) ?? lastUserAt
                continue
            }
            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  containsText(message["content"])
            else {
                continue
            }
            lastAssistantAt = timestamp(in: object) ?? lastAssistantAt
        }

        let completed: Bool
        if let lastUserAt, let lastAssistantAt {
            completed = lastAssistantAt >= lastUserAt
        } else {
            completed = lastUserAt == nil && lastAssistantAt != nil
        }
        return ClaudeTranscriptSnapshot(
            lastUserTurnID: lastUserTurnID,
            lastUserAt: lastUserAt,
            lastAssistantAt: lastAssistantAt,
            hasCompletedLatestTurn: completed
        )
    }

    private static func containsText(_ content: Any?) -> Bool {
        if let text = content as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let items = content as? [[String: Any]] else { return false }
        return items.contains {
            ($0["type"] as? String) == "text"
                && !(($0["text"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
        }
    }

    private static func timestamp(in object: [String: Any]) -> Date? {
        guard let value = object["timestamp"] as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func jsonLines(_ data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
}
