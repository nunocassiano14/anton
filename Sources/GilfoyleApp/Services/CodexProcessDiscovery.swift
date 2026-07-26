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
    let taskTurnID: String?
    let taskStartedAt: Date?
    let activity: String?
    let terminal: TerminalContext
}

final class CodingAgentProcessDiscovery {
    private let queue = DispatchQueue(label: "com.augustalabs.anton.agent-discovery")
    private var timer: DispatchSourceTimer?
    private var cachedTerminalInventory = TerminalInventory()
    private var terminalInventoryRefreshedAt = Date.distantPast
    private var cachedWorkingDirectories: [Int32: (path: String?, storedAt: Date)] = [:]

    func discoverNow() -> [DiscoveredAgentSession] {
        queue.sync {
            discover()
        }
    }

    func start(onUpdate: @escaping @Sendable ([DiscoveredAgentSession]) -> Void) {
        stop()
        refresh(onUpdate: onUpdate)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Hooks are immediate. This fallback only needs to reconcile sessions
        // opened before Anton and lifecycle updates missed by hooks. Keep the
        // scan deliberately infrequent because it runs `ps`, `lsof`, and local
        // metadata lookups.
        timer.schedule(deadline: .now() + 5, repeating: 5)
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
        queue.async { [weak self] in
            guard let self else { return }
            onUpdate(discover())
        }
    }

    private func discover() -> [DiscoveredAgentSession] {
        let processes = Self.psLines(arguments: ["-axo", "pid=,tty=,args="])
        let candidates: [(
            processID: Int32,
            rawTTY: String,
            agent: AgentKind
        )] = processes.compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let processID = Int32(fields[0]) else {
                return nil
            }
            let arguments = String(fields[2])
            guard
                !arguments.contains(" app-server"),
                let agent = AgentProcessClassifier.agentKind(for: arguments)
            else {
                return nil
            }
            let rawTTY = String(fields[1])
            guard rawTTY != "??", rawTTY != "-" else { return nil }
            return (processID, rawTTY, agent)
        }
        let liveProcessIDs = Set(candidates.map(\.processID))
        cachedWorkingDirectories = cachedWorkingDirectories.filter {
            liveProcessIDs.contains($0.key)
        }
        LocalAgentSessionMetadata.pruneCaches(liveProcessIDs: liveProcessIDs)

        // The hook bridge remains live even with no CLI process. Avoid
        // launching AppleScript, lsof, and sqlite helpers during those idle
        // periods; one inexpensive `ps` scan is sufficient.
        guard !candidates.isEmpty else { return [] }

        if Date().timeIntervalSince(terminalInventoryRefreshedAt) >= 30 {
            cachedTerminalInventory = TerminalInventory.read(
                terminalRunning: processes.contains {
                    $0.contains("/Terminal.app/Contents/MacOS/Terminal")
                },
                iTermRunning: processes.contains {
                    $0.contains("/iTerm.app/Contents/MacOS/iTerm2")
                        || $0.contains("/iTerm2.app/Contents/MacOS/iTerm2")
                }
            )
            terminalInventoryRefreshedAt = Date()
        }
        let terminalInventory = cachedTerminalInventory

        return candidates.map { candidate in
            let processID = candidate.processID
            let agent = candidate.agent
            let rawTTY = candidate.rawTTY
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
                taskTurnID: metadata.taskTurnID,
                taskStartedAt: metadata.taskStartedAt,
                activity: metadata.activity,
                terminal: terminal
            )
        }
    }

    private func workingDirectory(for processID: Int32) -> String? {
        if let cached = cachedWorkingDirectories[processID],
           Date().timeIntervalSince(cached.storedAt) < 60 {
            return cached.path
        }
        let path = Self.workingDirectory(for: processID)
        cachedWorkingDirectories[processID] = (path, Date())
        return path
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

    init(
        terminalTitles: [String: String] = [:],
        iTermSessions: [String: ITermSession] = [:]
    ) {
        self.terminalTitles = terminalTitles
        self.iTermSessions = iTermSessions
    }

    static func read(
        terminalRunning: Bool,
        iTermRunning: Bool
    ) -> TerminalInventory {
        let terminalValues = terminalRunning
            ? runAppleScript(terminalTTYScript)
            : []
        let iTermValues = iTermRunning
            ? runAppleScript(iTermTTYScript)
            : []
        let parsed = TerminalInventoryParser.parse(
            terminalLines: terminalValues,
            iTermLines: iTermValues
        )

        return TerminalInventory(
            terminalTitles: parsed.terminalTitles,
            iTermSessions: parsed.iTermSessions.mapValues {
                ITermSession(
                    identifier: $0.identifier,
                    title: $0.title
                )
            }
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
            let timeout = Date().addingTimeInterval(5)
            while process.isRunning && Date() < timeout {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                return []
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)
            else {
                return []
            }
            return text
                .split(whereSeparator: \.isNewline)
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
        set AppleScript's text item delimiters to linefeed
        set output to values as text
        set AppleScript's text item delimiters to ""
        return output
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
        set AppleScript's text item delimiters to linefeed
        set output to values as text
        set AppleScript's text item delimiters to ""
        return output
    end tell
    """
}
