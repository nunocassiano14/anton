import Darwin
import Foundation
import GilfoyleCore

private enum HookRuntime {
    static func main() {
        guard let agent = parseAgent(arguments: CommandLine.arguments) else {
            return
        }
        let adapter = AgentLifecycleAdapters.adapter(for: agent)
        guard let token = IPCTokenStore.load() else {
            return
        }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard !input.isEmpty else { return }

        do {
            let terminal = TerminalContextResolver.resolve(agent: agent)
            var request = try adapter.decode(
                data: input,
                terminal: terminal,
                token: token
            )
            if let launchToken = ProcessInfo.processInfo.environment[
                "ANTON_LAUNCH_TOKEN"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !launchToken.isEmpty
            {
                request.event.metadata["antonLaunchToken"] = .string(launchToken)
            }
            let interactive = request.event.name == "PermissionRequest"
                || request.event.name == "Elicitation"
                || (
                    request.event.name == "PreToolUse"
                    && SessionReducer.isQuestionTool(request.event.toolName)
                )
            let response = try UnixSocketClient().send(
                request,
                timeout: interactive ? 640 : 3
            )
            emitHookOutput(for: request, response: response, adapter: adapter)
        } catch {
            debug(error)
        }
    }

    private static func parseAgent(arguments: [String]) -> AgentKind? {
        guard
            let index = arguments.firstIndex(of: "--agent"),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return AgentKind(rawValue: arguments[index + 1])
    }

    private static func emitHookOutput(
        for request: BridgeRequest,
        response: BridgeResponse,
        adapter: any AgentLifecycleAdapting
    ) {
        do {
            if let data = try adapter.render(request: request, response: response) {
                FileHandle.standardOutput.write(data)
            }
        } catch {
            debug(error)
        }
    }

    private static func debug(_ error: Error) {
        guard ProcessInfo.processInfo.environment["ANTON_DEBUG"] == "1" else { return }
        let line = "[Anton] \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

private enum TerminalContextResolver {
    static func resolve(
        agent: AgentKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalContext {
        let termProgram = environment["TERM_PROGRAM"]
        let kind: TerminalKind
        if termProgram?.lowercased().contains("iterm") == true
            || environment["ITERM_SESSION_ID"] != nil {
            kind = .iTerm
        } else if termProgram == "Apple_Terminal" || environment["TERM_SESSION_ID"] != nil {
            kind = .terminal
        } else {
            kind = .unknown
        }

        let processContext = discoverProcessContext(
            startingAt: getppid(),
            agent: agent
        )
        return TerminalContext(
            kind: kind,
            termProgram: termProgram,
            terminalSessionID: environment["TERM_SESSION_ID"],
            iTermSessionID: environment["ITERM_SESSION_ID"],
            tty: environment["TTY"] ?? processContext.tty,
            processID: processContext.agentPID,
            parentProcessID: getppid()
        )
    }

    private static func discoverProcessContext(
        startingAt initialPID: Int32,
        agent: AgentKind
    ) -> (tty: String?, agentPID: Int32?) {
        var pid = initialPID
        var discoveredTTY: String?
        var discoveredAgentPID: Int32?
        for _ in 0..<12 where pid > 1 {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = [
                "-o", "ppid=",
                "-o", "tty=",
                "-o", "comm=",
                "-o", "args=",
                "-p", String(pid)
            ]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                break
            }
            guard
                let text = String(
                    data: output.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else {
                break
            }
            let components = text.split(whereSeparator: \.isWhitespace)
            guard components.count >= 4, let parent = Int32(components[0]) else {
                break
            }
            let tty = String(components[1])
            if discoveredTTY == nil, tty != "??", tty != "-" {
                discoveredTTY = tty.hasPrefix("/") ? tty : "/dev/\(tty)"
            }

            let command = URL(fileURLWithPath: String(components[2])).lastPathComponent
                .lowercased()
            let invokedAs = URL(fileURLWithPath: String(components[3])).lastPathComponent
                .lowercased()
            if command == agent.rawValue || invokedAs == agent.rawValue {
                discoveredAgentPID = pid
                break
            }
            pid = parent
        }
        return (discoveredTTY, discoveredAgentPID)
    }
}

HookRuntime.main()
