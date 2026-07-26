import Foundation

public struct CodexRolloutSnapshot: Equatable, Sendable {
    public let state: AgentSessionState
    public let turnID: String?
    public let taskStartedAt: Date?
    public let activity: String?

    public init(
        state: AgentSessionState,
        turnID: String? = nil,
        taskStartedAt: Date? = nil,
        activity: String? = nil
    ) {
        self.state = state
        self.turnID = turnID
        self.taskStartedAt = taskStartedAt
        self.activity = activity
    }
}

/// Extracts the current Codex task boundary from a bounded local rollout
/// fragment. Prompts and responses are never retained. Tool calls contribute
/// only a short local activity label; command text and tool output are not
/// exposed by the snapshot.
public enum CodexRolloutLifecycle {
    public static func state(in data: Data) -> AgentSessionState {
        snapshot(in: data).state
    }

    public static func snapshot(in data: Data) -> CodexRolloutSnapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            return CodexRolloutSnapshot(state: .idle)
        }

        var state = AgentSessionState.idle
        var turnID: String?
        var taskStartedAt: Date?
        var activity: String?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }

            if event["type"] as? String == "event_msg", type == "task_complete" {
                state = .finished
                turnID = payload["turn_id"] as? String
                taskStartedAt = timestamp(in: payload)
                activity = "Response ready"
            } else if event["type"] as? String == "event_msg", type == "task_started" {
                state = .working
                turnID = payload["turn_id"] as? String
                taskStartedAt = timestamp(in: payload)
                activity = "Thinking"
            } else if event["type"] as? String == "response_item",
                      state == .working,
                      type == "function_call" || type == "custom_tool_call"
            {
                activity = activityName(for: payload)
            }
        }
        return CodexRolloutSnapshot(
            state: state,
            turnID: turnID,
            taskStartedAt: taskStartedAt,
            activity: activity
        )
    }

    private static func timestamp(in payload: [String: Any]) -> Date? {
        (payload["started_at"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
    }

    private static func activityName(for payload: [String: Any]) -> String {
        let name = (payload["name"] as? String ?? "").lowercased()
        let arguments = decodedArguments(payload["arguments"])

        switch name {
        case "run":
            if arguments["search_query"] != nil || arguments["image_query"] != nil {
                return "Searching the web"
            }
            if arguments["open"] != nil || arguments["click"] != nil || arguments["find"] != nil {
                return "Reading web sources"
            }
            if arguments["screenshot"] != nil {
                return "Reviewing a PDF"
            }
            if arguments["weather"] != nil || arguments["finance"] != nil
                || arguments["sports"] != nil || arguments["time"] != nil
            {
                return "Checking live data"
            }
            return "Using the web"
        case "exec_command":
            return commandActivity(arguments["cmd"] as? String)
        case "write_stdin":
            return "Continuing a command"
        case "view_image":
            return fileActivity(
                prefix: "Viewing",
                path: arguments["path"] as? String,
                fallback: "Viewing an image"
            )
        case "apply_patch", "edit", "write":
            return "Editing files"
        case "update_plan":
            return "Updating the plan"
        case "request_user_input":
            return "Preparing a question"
        case "tool_search":
            return "Finding the right tool"
        case "js", "exec":
            return "Running automation"
        case "wait":
            return "Waiting for a task"
        case "search_openai_docs", "fetch_openai_doc":
            return "Searching OpenAI docs"
        case "fireflies_search", "fireflies_get_transcript", "fireflies_get_transcripts":
            return "Reviewing call transcripts"
        case "write_html", "update_styles", "set_text_content", "create_artboard",
             "create_page", "delete_nodes", "duplicate_nodes", "rename_nodes":
            return "Editing a Paper design"
        case "get_screenshot", "get_tree_summary", "get_computed_styles", "get_jsx":
            return "Reviewing a Paper design"
        case "open_file", "get_basic_info", "get_selection", "list_files", "find_nodes":
            return "Inspecting Paper"
        case "_deploy_private_site_version", "_save_site_version", "_create_site":
            return "Publishing a site"
        case "_get_deployment_status", "_get_site":
            return "Checking a deployment"
        case "imagegen", "image_gen":
            return "Generating an image"
        default:
            guard !name.isEmpty else { return "Working" }
            let readable = name
                .replacingOccurrences(of: "__", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            return "Using \(readable)"
        }
    }

    private static func decodedArguments(_ value: Any?) -> [String: Any] {
        if let object = value as? [String: Any] {
            return object
        }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    private static func commandActivity(_ command: String?) -> String {
        guard let command else { return "Running a command" }
        let normalized = command.lowercased()
        if normalized.contains("swift test")
            || normalized.contains("npm test")
            || normalized.contains("pnpm test")
            || normalized.contains("pytest")
            || normalized.contains("scripts/test")
        {
            return "Running tests"
        }
        if normalized.contains("swift build")
            || normalized.contains("npm run build")
            || normalized.contains("pnpm build")
            || normalized.contains("build-app")
        {
            return "Building the app"
        }
        if normalized.contains("install-local") {
            return "Installing Anton"
        }
        if normalized.contains("rg ") || normalized.contains("grep ")
            || normalized.contains("find ")
        {
            return "Searching the codebase"
        }
        if normalized.contains("sed ") || normalized.contains("head ")
            || normalized.contains("tail ")
        {
            if let filename = firstFilename(in: command) {
                return "Reading \(filename)"
            }
            return "Reading files"
        }
        if normalized.contains("git diff") || normalized.contains("git status")
            || normalized.contains("git log")
        {
            return "Inspecting changes"
        }
        return "Running a command"
    }

    private static func fileActivity(prefix: String, path: String?, fallback: String) -> String {
        guard let path, !path.isEmpty else { return fallback }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        return filename.isEmpty ? fallback : "\(prefix) \(filename)"
    }

    private static func firstFilename(in command: String) -> String? {
        let pattern = #"[A-Za-z0-9_.-]+\.(?:swift|md|json|jsonl|toml|yaml|yml|js|ts|tsx|jsx|py|rs|go|sh|png|pdf)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: command,
                  range: NSRange(command.startIndex..., in: command)
              ),
              let range = Range(match.range, in: command)
        else {
            return nil
        }
        return String(command[range])
    }
}
