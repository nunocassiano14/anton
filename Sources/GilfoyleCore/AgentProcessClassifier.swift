import Foundation

/// Identifies supported CLI agents from the command line reported by `ps`.
/// Package-manager installations commonly launch through Node, so the first
/// executable alone is not sufficient.
public enum AgentProcessClassifier {
    public static func agentKind(for arguments: String) -> AgentKind? {
        let tokens = arguments
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let first = tokens.first else { return nil }
        if first.lowercased().contains(".app/contents/macos/") {
            return nil
        }

        let executable = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        switch executable {
        case "codex":
            return .codex
        case "claude":
            return .claude
        default:
            break
        }

        let normalized = arguments.lowercased()
        let isJavaScriptRuntime = ["node", "nodejs", "bun", "deno"].contains(executable)
        if isJavaScriptRuntime && normalized.contains("/@openai/codex/") {
            return .codex
        }
        if isJavaScriptRuntime && normalized.contains("/@anthropic-ai/claude-code/") {
            return .claude
        }
        return nil
    }
}
