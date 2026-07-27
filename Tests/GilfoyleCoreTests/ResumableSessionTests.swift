import Foundation
import Testing
@testable import GilfoyleCore

@Suite("Local session launcher")
struct ResumableSessionTests {
    @Test("Claude history keeps the latest valid row for each session")
    func parsesClaudeHistory() throws {
        let data = try #require(
            """
            {"display":"First prompt","project":"/tmp/alpha","sessionId":"claude-1","timestamp":1000}
            not-json
            {"display":"Latest prompt\\nwith detail","project":"/tmp/alpha","sessionId":"claude-1","timestamp":3000}
            {"display":"Second session","project":"/tmp/beta","sessionId":"claude-2","timestamp":2000}
            """.data(using: .utf8)
        )

        let sessions = ResumableSessionParser.claudeHistory(data)

        #expect(sessions.map(\.sessionID) == ["claude-1", "claude-2"])
        #expect(sessions[0].title == "Latest prompt")
        #expect(sessions[0].displayTitle == "Claude Code · alpha")
        #expect(sessions[0].preview == "Latest prompt\nwith detail")
        #expect(sessions[0].cwd == "/tmp/alpha")
        #expect(sessions[0].updatedAt == Date(timeIntervalSince1970: 3))
    }

    @Test("Codex database rows retain resume metadata and exclude archived duplicates")
    func parsesCodexThreads() throws {
        let data = try #require(
            """
            [
              {
                "id":"codex-1",
                "cwd":"/tmp/repo",
                "title":"Prompt-derived fallback",
                "explicit_name":"Launcher review",
                "updated_at_ms":5000,
                "model":"gpt-5.6-terra",
                "preview":"Inspect the current implementation",
                "git_branch":"feature/launcher",
                "archived":0
              },
              {
                "id":"codex-archived",
                "cwd":"/tmp/old",
                "title":"Old",
                "updated_at_ms":9000,
                "archived":1
              }
            ]
            """.data(using: .utf8)
        )

        let sessions = ResumableSessionParser.deduplicated(
            ResumableSessionParser.codexThreads(data)
        )

        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.id == "codex:codex-1")
        #expect(session.model == "gpt-5.6-terra")
        #expect(session.gitBranch == "feature/launcher")
        #expect(session.explicitName == "Launcher review")
        #expect(session.displayTitle == "Launcher review")
    }

    @Test("Visible title uses rename, then branch, and never prompt text")
    func visibleTitlePriority() {
        let renamed = fixture(
            agent: .codex,
            id: "renamed",
            title: "Long first prompt that must stay private",
            explicitName: "Anton",
            cwd: "/work/anton",
            gitBranch: "feature/catalog"
        )
        let branched = fixture(
            agent: .claude,
            id: "branched",
            title: "/resume old-session",
            cwd: "/work/anton",
            gitBranch: "feature/catalog"
        )
        let unnamed = fixture(
            agent: .claude,
            id: "unnamed",
            title: "Another prompt",
            cwd: "/work/anton"
        )

        #expect(renamed.displayTitle == "Anton")
        #expect(branched.displayTitle == "feature/catalog")
        #expect(unnamed.displayTitle == "Claude Code · anton")
    }

    @Test("Claude transcript extracts explicit rename and historical branch")
    func parsesClaudeTranscriptMetadata() throws {
        let data = try #require(
            """
            {"type":"user","sessionId":"claude-1","gitBranch":"feature/old"}
            {"type":"custom-title","sessionId":"claude-1","customTitle":"Baltic design"}
            {"type":"assistant","sessionId":"claude-1","gitBranch":"feature/current"}
            {"type":"custom-title","sessionId":"claude-1","customTitle":"Baltic final"}
            """.data(using: .utf8)
        )

        let metadata = ResumableSessionParser.claudeTranscriptMetadata(data)
        let titles = ResumableSessionParser.claudeCustomTitles(data)

        #expect(metadata.explicitName == "Baltic final")
        #expect(metadata.gitBranch == "feature/current")
        #expect(titles == ["claude-1": "Baltic final"])
    }

    @Test("Codex session index overlays rename without losing database metadata")
    func mergesCodexRenameIndex() throws {
        let database = try #require(
            """
            [{
              "id":"codex-1",
              "cwd":"/tmp/repo",
              "title":"First prompt",
              "updated_at_ms":5000,
              "model":"gpt-5.6-terra",
              "git_branch":"feature/launcher",
              "archived":0
            }]
            """.data(using: .utf8)
        )
        let index = try #require(
            """
            {"id":"codex-1","thread_name":"Character design specs","updated_at":"1970-01-01T00:00:03.000Z"}
            """.data(using: .utf8)
        )

        let sessions = ResumableSessionParser.mergingMetadata(
            into: ResumableSessionParser.codexThreads(database),
            from: ResumableSessionParser.codexIndex(index)
        )
        let session = try #require(sessions.first)

        #expect(session.displayTitle == "Character design specs")
        #expect(session.cwd == "/tmp/repo")
        #expect(session.model == "gpt-5.6-terra")
        #expect(session.gitBranch == "feature/launcher")
        #expect(session.updatedAt == Date(timeIntervalSince1970: 5))
    }

    @Test("Search and workspace filters are deterministic")
    func filtersCatalog() {
        let sessions = [
            fixture(
                agent: .codex,
                id: "one",
                title: "Baltic review",
                cwd: "/work/baltic",
                model: "gpt-5.6-terra"
            ),
            fixture(
                agent: .claude,
                id: "two",
                title: "Anton fixes",
                cwd: "/work/anton",
                model: "opus"
            )
        ]

        #expect(
            ResumableSessionParser.filtered(
                sessions,
                query: "",
                workspace: "/work/anton",
                allWorkspaces: false
            ).map(\.sessionID) == ["two"]
        )
        #expect(
            ResumableSessionParser.filtered(
                sessions,
                query: "terra",
                workspace: nil,
                allWorkspaces: true
            ).map(\.sessionID) == ["one"]
        )
    }

    @Test("Launch commands quote paths and never include the initial prompt")
    func buildsSafeNewCommand() throws {
        let plan = AgentSessionLaunchPlan(
            launchToken: "token-1",
            agent: .claude,
            mode: .new,
            executablePath: "/opt/bin/claude",
            cwd: "/tmp/Nuno's workspace",
            sessionName: "Baltic's review",
            terminalKind: .terminal
        )

        let command = try AgentLaunchCommandBuilder.command(for: plan)

        #expect(command.hasPrefix("cd -- '/tmp/Nuno'\\''s workspace' && exec "))
        #expect(command.contains("'ANTON_LAUNCH_TOKEN=token-1'"))
        #expect(command.contains("'/opt/bin/claude' '--name' 'Baltic'\\''s review'"))
        #expect(!command.contains("initial prompt"))
        #expect(!command.contains("\n"))
    }

    @Test("Claude and Codex resume/fork use their native CLI contracts")
    func buildsResumeAndForkCommands() throws {
        let claudeResume = try AgentLaunchCommandBuilder.command(
            for: plan(agent: .claude, mode: .resume)
        )
        let claudeFork = try AgentLaunchCommandBuilder.command(
            for: plan(agent: .claude, mode: .fork)
        )
        let codexResume = try AgentLaunchCommandBuilder.command(
            for: plan(agent: .codex, mode: .resume)
        )
        let codexFork = try AgentLaunchCommandBuilder.command(
            for: plan(agent: .codex, mode: .fork)
        )

        #expect(claudeResume.hasSuffix("'--resume' 'saved-id'"))
        #expect(claudeFork.hasSuffix("'--resume' 'saved-id' '--fork-session'"))
        #expect(codexResume.hasSuffix("'resume' 'saved-id'"))
        #expect(codexFork.hasSuffix("'fork' 'saved-id'"))
    }

    @Test("Resume without a saved ID is rejected before opening a terminal")
    func rejectsIncompleteResume() {
        let incomplete = AgentSessionLaunchPlan(
            launchToken: "token",
            agent: .codex,
            mode: .resume,
            executablePath: "/opt/bin/codex",
            cwd: "/tmp/repo",
            terminalKind: .terminal
        )

        #expect(throws: AgentSessionLaunchError.missingPriorSession) {
            try AgentLaunchCommandBuilder.command(for: incomplete)
        }
    }

    private func fixture(
        agent: AgentKind,
        id: String,
        title: String,
        explicitName: String? = nil,
        cwd: String,
        model: String? = nil,
        gitBranch: String? = nil
    ) -> ResumableAgentSession {
        ResumableAgentSession(
            agent: agent,
            sessionID: id,
            title: title,
            explicitName: explicitName,
            cwd: cwd,
            updatedAt: Date(),
            model: model,
            gitBranch: gitBranch
        )
    }

    private func plan(
        agent: AgentKind,
        mode: AgentSessionLaunchMode
    ) -> AgentSessionLaunchPlan {
        AgentSessionLaunchPlan(
            launchToken: "token",
            agent: agent,
            mode: mode,
            executablePath: agent == .claude ? "/opt/bin/claude" : "/opt/bin/codex",
            cwd: "/tmp/repo",
            priorSessionID: "saved-id",
            terminalKind: .terminal
        )
    }
}
