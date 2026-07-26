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
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? nil : String(formatted.prefix(8_000))
    }
}
