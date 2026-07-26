import Foundation

public enum IntegrationState: String, Codable, Sendable {
    case missing
    case installed
    case incomplete
    case unavailable
}

public struct IntegrationStatus: Equatable, Sendable {
    public var agent: AgentKind
    public var state: IntegrationState
    public var detail: String
    public var configurationURL: URL

    public init(
        agent: AgentKind,
        state: IntegrationState,
        detail: String,
        configurationURL: URL
    ) {
        self.agent = agent
        self.state = state
        self.detail = detail
        self.configurationURL = configurationURL
    }
}

public struct IntegrationChange: Equatable, Sendable {
    public var configurationURL: URL
    public var backupURL: URL?
    public var changed: Bool

    public init(configurationURL: URL, backupURL: URL?, changed: Bool) {
        self.configurationURL = configurationURL
        self.backupURL = backupURL
        self.changed = changed
    }
}

public final class IntegrationInstaller {
    public static let marker = "anton-hook"
    public static let legacyMarker = "gilfoyle-hook"

    public let homeURL: URL
    public let helperURL: URL
    public let backupsURL: URL

    private let fileManager: FileManager

    public init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperURL: URL,
        backupsURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.homeURL = homeURL
        self.helperURL = helperURL
        self.backupsURL = backupsURL ?? AntonPaths.backupsURL(home: homeURL)
        self.fileManager = fileManager
    }

    public var claudeSettingsURL: URL {
        homeURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public var codexHooksURL: URL {
        homeURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    public func installClaude() throws -> IntegrationChange {
        try install(
            at: claudeSettingsURL,
            agent: .claude,
            events: Self.claudeEvents,
            topLevelDescription: nil
        )
    }

    public func installCodex() throws -> IntegrationChange {
        try install(
            at: codexHooksURL,
            agent: .codex,
            events: Self.codexEvents,
            topLevelDescription: "Anton local lifecycle integration. Remove through Anton Settings."
        )
    }

    public func removeClaude() throws -> IntegrationChange {
        try remove(at: claudeSettingsURL)
    }

    public func removeCodex() throws -> IntegrationChange {
        try remove(at: codexHooksURL)
    }

    public func status(for agent: AgentKind) -> IntegrationStatus {
        let url = agent == .claude ? claudeSettingsURL : codexHooksURL
        let expected = agent == .claude ? Self.claudeEvents : Self.codexEvents
        guard fileManager.fileExists(atPath: url.path) else {
            return IntegrationStatus(
                agent: agent,
                state: .missing,
                detail: "Integration is not installed.",
                configurationURL: url
            )
        }

        guard
            let root = try? loadObject(at: url),
            let hooks = root["hooks"] as? [String: Any]
        else {
            return IntegrationStatus(
                agent: agent,
                state: .incomplete,
                detail: "The configuration exists but could not be inspected.",
                configurationURL: url
            )
        }

        let installed = Set(expected.filter { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                containsExpectedHandler(group, agent: agent)
            }
        })

        if installed.count == expected.count {
            return IntegrationStatus(
                agent: agent,
                state: .installed,
                detail: "All lifecycle hooks are installed.",
                configurationURL: url
            )
        }
        let hasOutdatedAntonHandler = expected.contains { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains(where: containsAntonHandler)
        }
        if installed.isEmpty, !hasOutdatedAntonHandler {
            return IntegrationStatus(
                agent: agent,
                state: .missing,
                detail: "Integration is not installed.",
                configurationURL: url
            )
        }
        return IntegrationStatus(
            agent: agent,
            state: .incomplete,
            detail: hasOutdatedAntonHandler
                ? "Integration needs repair for the current app location."
                : "\(installed.count) of \(expected.count) lifecycle hooks are installed.",
            configurationURL: url
        )
    }

    private func install(
        at url: URL,
        agent: AgentKind,
        events: [String],
        topLevelDescription: String?
    ) throws -> IntegrationChange {
        var root = try loadObjectIfPresent(at: url)
        var changed = false
        if let topLevelDescription,
           root["description"] == nil
            || root["description"] as? String == "Gilfoyle local lifecycle integration. Remove through Gilfoyle Settings." {
            root["description"] = topLevelDescription
            changed = true
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let markerCount = groups.reduce(0) {
                $0 + antonHandlerCount(in: $1)
            }
            let containsExpected = groups.contains {
                containsExpectedHandler($0, agent: agent)
            }
            if markerCount == 1, containsExpected {
                continue
            }
            groups = removingAntonHandlers(from: groups)
            groups.append(hookGroup(event: event, agent: agent))
            hooks[event] = groups
            changed = true
        }
        root["hooks"] = hooks

        guard changed else {
            return IntegrationChange(configurationURL: url, backupURL: nil, changed: false)
        }

        let backup = try backupIfPresent(url)
        try write(root, to: url)
        return IntegrationChange(configurationURL: url, backupURL: backup, changed: true)
    }

    private func remove(at url: URL) throws -> IntegrationChange {
        guard fileManager.fileExists(atPath: url.path) else {
            return IntegrationChange(configurationURL: url, backupURL: nil, changed: false)
        }

        var root = try loadObject(at: url)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return IntegrationChange(configurationURL: url, backupURL: nil, changed: false)
        }

        var changed = false
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            var retainedGroups: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    retainedGroups.append(group)
                    continue
                }
                let retainedHandlers = handlers.filter { !containsAntonCommand($0) }
                if retainedHandlers.count != handlers.count {
                    changed = true
                }
                if !retainedHandlers.isEmpty {
                    group["hooks"] = retainedHandlers
                    retainedGroups.append(group)
                }
            }
            if retainedGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = retainedGroups
            }
        }

        guard changed else {
            return IntegrationChange(configurationURL: url, backupURL: nil, changed: false)
        }

        root["hooks"] = hooks
        let backup = try backupIfPresent(url)

        if url == codexHooksURL,
           hooks.isEmpty,
           Set(root.keys).subtracting(["description", "hooks"]).isEmpty {
            try fileManager.removeItem(at: url)
        } else {
            try write(root, to: url)
        }

        return IntegrationChange(configurationURL: url, backupURL: backup, changed: true)
    }

    private func hookGroup(event: String, agent: AgentKind) -> [String: Any] {
        var handler: [String: Any] = [
            "type": "command",
            "command": "\(shellQuoted(helperURL.path)) --agent \(agent.rawValue)",
            "statusMessage": "Anton",
            "timeout": timeout(for: event)
        ]
        if event == "SessionEnd" {
            handler.removeValue(forKey: "statusMessage")
        }
        return [
            "hooks": [handler]
        ]
    }

    private func timeout(for event: String) -> Int {
        switch event {
        case "PermissionRequest", "PreToolUse", "Elicitation":
            return 650
        case "SessionEnd":
            return 3
        default:
            return 10
        }
    }

    private func containsAntonHandler(_ group: [String: Any]) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains(where: containsAntonCommand)
    }

    private func containsExpectedHandler(
        _ group: [String: Any],
        agent: AgentKind
    ) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains {
            ($0["command"] as? String) == expectedCommand(agent: agent)
        }
    }

    private func antonHandlerCount(in group: [String: Any]) -> Int {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return 0 }
        return handlers.filter(containsAntonCommand).count
    }

    private func removingAntonHandlers(
        from groups: [[String: Any]]
    ) -> [[String: Any]] {
        groups.compactMap { original in
            var group = original
            guard let handlers = group["hooks"] as? [[String: Any]] else {
                return group
            }
            let retained = handlers.filter { !containsAntonCommand($0) }
            guard !retained.isEmpty else { return nil }
            group["hooks"] = retained
            return group
        }
    }

    private func containsAntonCommand(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        return command.contains(Self.marker) || command.contains(Self.legacyMarker)
    }

    private func expectedCommand(agent: AgentKind) -> String {
        "\(shellQuoted(helperURL.path)) --agent \(agent.rawValue)"
    }

    private func loadObjectIfPresent(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        return try loadObject(at: url)
    }

    private func loadObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(
                domain: "Anton.IntegrationInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not a JSON object."]
            )
        }
        return dictionary
    }

    private func write(_ root: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existingAttributes = try? fileManager.attributesOfItem(atPath: url.path)
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        try data.write(to: url, options: .atomic)

        let permissions = existingAttributes?[.posixPermissions] ?? 0o600
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func backupIfPresent(_ url: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let folderName = "\(formatter.string(from: Date()))-\(uniqueSuffix)"
        let folder = backupsURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let agentFolder = folder.appendingPathComponent(
            url == claudeSettingsURL ? "claude" : "codex",
            isDirectory: true
        )
        try fileManager.createDirectory(at: agentFolder, withIntermediateDirectories: true)
        let destination = agentFolder.appendingPathComponent(url.lastPathComponent)
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static let claudeEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "StopFailure",
        "Notification",
        "Elicitation"
    ]

    private static let codexEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Stop"
    ]
}
