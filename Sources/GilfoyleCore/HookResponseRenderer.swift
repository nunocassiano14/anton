import Foundation

public enum HookResponseRenderer {
    public static func render(
        request: BridgeRequest,
        response: BridgeResponse
    ) throws -> Data? {
        let object: [String: Any]?
        switch request.event.name {
        case "PermissionRequest":
            object = permissionOutput(response: response)
        case "PreToolUse" where SessionReducer.isQuestionTool(request.event.toolName):
            object = questionOutput(request: request, response: response)
        case "Elicitation":
            object = elicitationOutput(response: response)
        case "Stop" where request.agent == .codex:
            // Codex Stop hooks expect JSON on successful stdout. An empty
            // object acknowledges the event without continuing the turn.
            object = [:]
        default:
            object = nil
        }

        guard let object else { return nil }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw NSError(
                domain: "Anton.HookResponseRenderer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Hook output is not valid JSON."]
            )
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func permissionOutput(response: BridgeResponse) -> [String: Any]? {
        switch response.decision {
        case .allow:
            return [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": ["behavior": "allow"]
                ]
            ]
        case .deny, .cancel:
            return [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "deny",
                        "message": response.message ?? "Denied in Anton."
                    ]
                ]
            ]
        default:
            return nil
        }
    }

    private static func questionOutput(
        request: BridgeRequest,
        response: BridgeResponse
    ) -> [String: Any]? {
        guard response.decision == .answer else {
            if response.decision == .cancel || response.decision == .deny {
                return [
                    "decision": "block",
                    "reason": response.message ?? "The user cancelled this question in Anton."
                ]
            }
            return nil
        }

        let answerPayload = response.payload?.foundationValue ?? [:]
        if request.agent == .claude {
            var updatedInput = request.event.toolInput?.foundationValue as? [String: Any] ?? [:]
            if let payload = answerPayload as? [String: Any],
               let answers = payload["answers"] {
                updatedInput["answers"] = answers
            } else {
                updatedInput["answers"] = answerPayload
            }
            return [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": updatedInput
                ]
            ]
        }

        let rendered: String
        if JSONSerialization.isValidJSONObject(answerPayload),
           let data = try? JSONSerialization.data(withJSONObject: answerPayload),
           let text = String(data: data, encoding: .utf8) {
            rendered = text
        } else {
            rendered = String(describing: answerPayload)
        }
        return [
            "decision": "block",
            "reason": "The user answered through Anton: \(rendered). Treat this as the authoritative answer and continue."
        ]
    }

    private static func elicitationOutput(response: BridgeResponse) -> [String: Any]? {
        switch response.decision {
        case .answer, .allow:
            return [
                "hookSpecificOutput": [
                    "hookEventName": "Elicitation",
                    "action": "accept",
                    "content": response.payload?.foundationValue ?? [:]
                ]
            ]
        case .deny:
            return [
                "hookSpecificOutput": [
                    "hookEventName": "Elicitation",
                    "action": "decline",
                    "content": [:]
                ]
            ]
        case .cancel:
            return [
                "hookSpecificOutput": [
                    "hookEventName": "Elicitation",
                    "action": "cancel",
                    "content": [:]
                ]
            ]
        default:
            return nil
        }
    }
}
