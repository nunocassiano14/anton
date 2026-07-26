import Foundation
import GilfoyleCore

/// Local fallback for CLI sessions that were already running before Anton
/// launched. Normal lifecycle hooks remain the source of truth; this only
/// supplies a live process/TTY/cwd placeholder until that first hook arrives.
struct DiscoveredAgentSession: Sendable {
    let agent: AgentKind
    let processID: Int32
    let tty: String
    let cwd: String
    let sessionName: String?
    let model: String?
    let lastResponsePreview: String?
    let state: AgentSessionState
    let terminal: TerminalContext
}

final class CodingAgentProcessDiscovery {
    private let queue = DispatchQueue(label: "com.augustalabs.anton.agent-discovery")
    private var timer: DispatchSourceTimer?

    func discoverNow() -> [DiscoveredAgentSession] {
        Self.discover()
    }

    func start(onUpdate: @escaping @Sendable ([DiscoveredAgentSession]) -> Void) {
        stop()
        refresh(onUpdate: onUpdate)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Hooks are immediate, but sessions opened before Anton and local
        // rollout-only completions rely on this fallback. Two seconds keeps
        // the board feeling live without an intrusive notification mechanism.
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.refresh(onUpdate: onUpdate)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func refresh(onUpdate: @escaping @Sendable ([DiscoveredAgentSession]) -> Void) {
        queue.async {
            onUpdate(Self.discover())
        }
    }

    private static func discover() -> [DiscoveredAgentSession] {
        let terminalInventory = TerminalInventory.read()
        let processes = psLines(arguments: ["-axo", "pid=,tty=,args="])

        return processes.compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard
                fields.count >= 3,
                let processID = Int32(fields[0]),
                let agent = agentKind(for: String(fields[2]))
            else {
                return nil
            }

            let arguments = String(fields[2])
            guard !arguments.contains(" app-server") else { return nil }

            let rawTTY = String(fields[1])
            guard rawTTY != "??", rawTTY != "-" else { return nil }
            let tty = rawTTY.hasPrefix("/") ? rawTTY : "/dev/\(rawTTY)"
            let metadata = LocalAgentSessionMetadata.read(agent: agent, processID: processID)
            let terminal: TerminalContext
            if let iTermSession = terminalInventory.iTermSessions[tty] {
                terminal = TerminalContext(
                    kind: .iTerm,
                    iTermSessionID: iTermSession.identifier,
                    tabTitle: iTermSession.title,
                    tty: tty,
                    processID: processID
                )
            } else if let terminalTitle = terminalInventory.terminalTitles[tty] {
                terminal = TerminalContext(
                    kind: .terminal,
                    tabTitle: terminalTitle,
                    tty: tty,
                    processID: processID
                )
            } else {
                terminal = TerminalContext(
                    kind: .unknown,
                    tty: tty,
                    processID: processID
                )
            }

            return DiscoveredAgentSession(
                agent: agent,
                processID: processID,
                tty: tty,
                cwd: metadata.cwd ?? workingDirectory(for: processID) ?? FileManager.default.homeDirectoryForCurrentUser.path,
                sessionName: metadata.name,
                model: metadata.model,
                lastResponsePreview: metadata.lastResponsePreview,
                state: metadata.state,
                terminal: terminal
            )
        }
    }

    private static func agentKind(for arguments: String) -> AgentKind? {
        guard let command = arguments.split(whereSeparator: \.isWhitespace).first else { return nil }
        switch URL(fileURLWithPath: String(command)).lastPathComponent.lowercased() {
        case "codex": return .codex
        case "claude": return .claude
        default: return nil
        }
    }

    private static func workingDirectory(for processID: Int32) -> String? {
        let lines = psLines(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(processID), "-d", "cwd", "-Fn"]
        )
        return lines.first(where: { $0.hasPrefix("n/") }).map { String($0.dropFirst()) }
    }

    private static func psLines(
        executable: String = "/bin/ps",
        arguments: [String]
    ) -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // `ps -axo args` can be larger than the pipe buffer on a busy
            // developer machine (Electron processes alone are enough). Read
            // while it runs; waiting first deadlocks and made existing CLI
            // sessions appear as if there were none.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)
            else {
                return []
            }
            return text.split(whereSeparator: \.isNewline).map(String.init)
        } catch {
            return []
        }
    }
}

private struct TerminalInventory {
    struct ITermSession {
        let identifier: String
        let title: String?
    }

    var terminalTitles: [String: String]
    var iTermSessions: [String: ITermSession]

    static func read() -> TerminalInventory {
        TerminalInventory(
            terminalTitles: Dictionary(
                uniqueKeysWithValues: runAppleScript(terminalTTYScript).compactMap { value in
                    let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return nil }
                    return (parts[0], parts[1])
                }
            ),
            iTermSessions: Dictionary(
                uniqueKeysWithValues: runAppleScript(iTermTTYScript).compactMap { value in
                    let parts = value.split(separator: "|", maxSplits: 2).map(String.init)
                    guard parts.count >= 2 else { return nil }
                    return (parts[0], ITermSession(
                        identifier: parts[1],
                        title: parts.count == 3 ? parts[2] : nil
                    ))
                }
            )
        )
    }

    private static func runAppleScript(_ source: String) -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)
            else {
                return []
            }
            return text
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    private static let terminalTTYScript = """
    tell application "Terminal"
        set values to {}
        repeat with terminalWindow in windows
            repeat with terminalTab in tabs of terminalWindow
                set titleText to custom title of terminalTab
                if selected of terminalTab then
                    set titleText to name of terminalWindow
                end if
                set end of values to (tty of terminalTab) & "|" & titleText
            end repeat
        end repeat
        return values
    end tell
    """

    private static let iTermTTYScript = """
    tell application "iTerm2"
        set values to {}
        repeat with terminalWindow in windows
            repeat with terminalTab in tabs of terminalWindow
                repeat with terminalSession in sessions of terminalTab
                    set end of values to (tty of terminalSession) & "|" & (unique ID of terminalSession) & "|" & (name of terminalSession)
                end repeat
            end repeat
        end repeat
        return values
    end tell
    """
}
