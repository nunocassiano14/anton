import Foundation

/// Small, local-only metadata extraction helpers. They intentionally return
/// just a selected model label rather than any conversation content.
public enum AgentModelMetadata {
    /// The selected Claude default is written immediately by `/model`, even
    /// when the already-running CLI has not emitted another API event yet.
    public static func configuredClaudeModel(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? String
        else { return nil }
        let value = cleanTerminalFormatting(model)
        return value.isEmpty ? nil : value
    }

    /// Claude records an interactive `/model` change as a normal transcript
    /// message before subsequent API events necessarily carry the new model.
    /// Prefer that newest explicit change over an older JSON `model` field.
    public static func latestClaudeModelChange(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"Set model to\s+[*_`]*([^*\n\r\"]+?)[*_`]*\s+and saved"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.matches(in: text, range: range).last,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = cleanTerminalFormatting(String(text[valueRange]))
        return value.isEmpty ? nil : value
    }

    private static func cleanTerminalFormatting(_ value: String) -> String {
        // Claude may write terminal styling either as literal ESC bytes or as
        // JSON-escaped `\\u001b` sequences. Neither is meaningful metadata.
        let literalPattern = #"\\u001b\[[0-9;]*m"#
        let escapedPattern = #"\u{001B}\[[0-9;]*m"#
        let literal = (try? NSRegularExpression(pattern: literalPattern))?
            .stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: ""
            ) ?? value
        let escaped = (try? NSRegularExpression(pattern: escapedPattern))?
            .stringByReplacingMatches(
                in: literal,
                range: NSRange(literal.startIndex..., in: literal),
                withTemplate: ""
            ) ?? literal
        return escaped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
