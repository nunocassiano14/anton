import Foundation

public enum HookInputParser {
    public static func parse(
        data: Data,
        agent: AgentKind,
        terminal: TerminalContext,
        token: String,
        requestID: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> BridgeRequest {
        let rawObject = try JSONSerialization.jsonObject(with: data)
        guard let raw = rawObject as? [String: Any] else {
            throw NSError(
                domain: "Anton.HookInputParser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Hook input must be a JSON object."]
            )
        }

        let eventName = raw["hook_event_name"] as? String ?? "Unknown"
        let sessionID = raw["session_id"] as? String ?? "unknown-\(requestID)"
        let cwd = raw["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let toolName = raw["tool_name"] as? String
        let rawToolInput = raw["tool_input"]
        let toolInput: JSONValue?
        if eventName == "PermissionRequest"
            || eventName == "Elicitation"
            || SessionReducer.isQuestionTool(toolName) {
            toolInput = try rawToolInput.map(JSONValue.init(any:))
        } else {
            toolInput = nil
        }

        var metadata: [String: JSONValue] = [:]
        for key in [
            "source",
            "reason",
            "notification_type",
            "message",
            "title",
            "mcp_server_name",
            "mode",
            "url",
            "elicitation_id",
            "requested_schema",
            "permission_suggestions",
            "error_details"
        ] {
            if let value = raw[key] {
                metadata[key] = try JSONValue(any: value)
            }
        }

        let assistantMessage = (raw["last_assistant_message"] as? String).map {
            String($0.prefix(8_000))
        }

        let event = HookEventPayload(
            name: eventName,
            sessionID: sessionID,
            turnID: raw["turn_id"] as? String,
            cwd: cwd,
            model: raw["model"] as? String,
            permissionMode: raw["permission_mode"] as? String,
            toolName: toolName,
            toolInput: toolInput,
            lastAssistantMessage: assistantMessage,
            error: raw["error"] as? String,
            metadata: metadata
        )

        return BridgeRequest(
            token: token,
            requestID: requestID,
            agent: agent,
            event: event,
            terminal: terminal,
            sentAt: now
        )
    }
}
