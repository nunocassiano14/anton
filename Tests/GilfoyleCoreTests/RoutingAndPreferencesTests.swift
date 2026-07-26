import Foundation
import Testing
@testable import GilfoyleCore

@Suite("Routing and preferences", .serialized)
struct RoutingAndPreferencesTests {
    @Test("Terminal routes require and preserve stable identities")
    func terminalRoutesAreExact() throws {
        let terminal = try TerminalRouteResolver.resolve(
            TerminalContext(kind: .terminal, tty: "/dev/ttys009")
        )
        #expect(terminal == .terminal(tty: "/dev/ttys009"))

        let iTerm = try TerminalRouteResolver.resolve(
            TerminalContext(
                kind: .iTerm,
                iTermSessionID: "w0t1p0:2B0E7F4A-1234",
                tty: "/dev/ttys010"
            )
        )
        #expect(
            iTerm == .iTerm(
                uniqueID: "2B0E7F4A-1234",
                tty: "/dev/ttys010"
            )
        )
        #expect(throws: TerminalRouteError.missingStableIdentifier) {
            try TerminalRouteResolver.resolve(TerminalContext(kind: .unknown))
        }
    }

    @Test("Background reply scripts contain no explicit terminal focus commands")
    func backgroundRepliesDoNotRequestTerminalFocus() {
        for script in [
            TerminalAutomationScripts.terminalSend,
            TerminalAutomationScripts.iTermSend
        ] {
            #expect(!script.contains("activate"))
            #expect(!script.contains("set selected"))
            #expect(!script.contains("select terminal"))
        }
        #expect(TerminalAutomationScripts.terminalFocus.contains("activate"))
        #expect(TerminalAutomationScripts.iTermFocus.contains("activate"))
    }

    @Test("Attention cards open automatically but remain user-collapsible")
    func attentionCardsCanBeCollapsed() {
        let opened = SessionDisclosurePolicy.initial(
            expandedByDefault: false,
            state: .finished
        )
        #expect(opened)
        #expect(!SessionDisclosurePolicy.toggled(opened))
        #expect(
            !SessionDisclosurePolicy.afterStateChange(
                current: false,
                state: .working
            )
        )
        #expect(
            SessionDisclosurePolicy.afterStateChange(
                current: false,
                state: .hasQuestion
            )
        )
    }

    @Test("Numbered lists keep indented continuation paragraphs in one run")
    func numberedListsKeepTheirSequence() {
        let blocks = MarkdownBlockParser.parse(
            """
            1. First market

               Supporting evidence for the first market.

            1. Second market

               Supporting evidence for the second market.

            1. Third market
            """
        )
        #expect(
            blocks == [
                .list(
                    [
                        "First market\n\nSupporting evidence for the first market.",
                        "Second market\n\nSupporting evidence for the second market.",
                        "Third market"
                    ],
                    ordered: true,
                    start: 1
                )
            ]
        )
    }

    @Test("Separate ordered-list blocks retain the numbers written by the agent")
    func orderedListBlocksKeepTheirStartingNumber() {
        let blocks = MarkdownBlockParser.parse(
            """
            1. First market
            Evidence for the first market.

            2. Second market
            Evidence for the second market.

            3. Third market
            """
        )
        #expect(
            blocks == [
                .list(["First market"], ordered: true, start: 1),
                .text("Evidence for the first market."),
                .list(["Second market"], ordered: true, start: 2),
                .text("Evidence for the second market."),
                .list(["Third market"], ordered: true, start: 3)
            ]
        )
    }

    @Test("Response previews preserve Markdown indentation")
    func responsePreviewsPreserveMarkdownIndentation() {
        let message = """
        1. First market

           Supporting evidence for the first market.

        1. Second market
        """
        let reduction = SessionReducer.reduce(
            existing: nil,
            request: BridgeRequest(
                token: "test",
                agent: .codex,
                event: HookEventPayload(
                    name: "Stop",
                    sessionID: "markdown-preview",
                    cwd: "/tmp/anton",
                    lastAssistantMessage: message
                ),
                terminal: TerminalContext(kind: .terminal, tty: "/dev/ttys001")
            )
        )
        #expect(
            reduction.session.lastResponsePreview?
                .contains("\n   Supporting evidence for the first market.") == true
        )
        #expect(
            MarkdownBlockParser.parse(reduction.session.lastResponsePreview ?? "")
                == [
                    .list(
                        [
                            "First market\n\nSupporting evidence for the first market.",
                            "Second market"
                        ],
                        ordered: true,
                        start: 1
                    )
                ]
        )
    }

    @Test("Approval and question responses return only to their own request")
    func interactionBrokerRoutesByRequestID() throws {
        let broker = InteractionResponseBroker()
        var approval: BridgeResponse?
        var question: BridgeResponse?
        broker.register(requestID: "approval") { approval = $0 }
        broker.register(requestID: "question") { question = $0 }

        #expect(
            broker.resolve(
                requestID: "question",
                response: BridgeResponse(
                    requestID: "question",
                    decision: .answer,
                    payload: .object(["answer": .string("SwiftUI")])
                )
            )
        )
        #expect(approval == nil)
        #expect(question?.decision == .answer)
        #expect(broker.pendingCount == 1)

        #expect(
            broker.resolve(
                requestID: "approval",
                response: BridgeResponse(requestID: "approval", decision: .deny)
            )
        )
        #expect(approval?.decision == .deny)
        #expect(broker.pendingCount == 0)
        #expect(
            !broker.resolve(
                requestID: "missing",
                response: BridgeResponse(requestID: "missing", decision: .allow)
            )
        )
    }

    @Test("All daily-use settings persist together")
    func settingsPersistenceRoundTrip() throws {
        let suiteName = "AntonTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = PreferencesRepository(defaults: defaults)
        let expected = StoredPreferences(
            shortcut: ShortcutConfiguration(
                keyCode: 11,
                command: true,
                option: false,
                control: true,
                shift: true
            ),
            onboardingComplete: true
        )

        try repository.save(expected)
        #expect(PreferencesRepository(defaults: defaults).load() == expected)
    }

    @Test("Anton adopts preferences from the previous local build once")
    func preferencesMigrateFromGilfoyle() throws {
        let suiteName = "AntonMigrationTests.\(UUID().uuidString)"
        let legacySuiteName = "GilfoyleMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            legacyDefaults.removePersistentDomain(forName: legacySuiteName)
        }
        let expected = StoredPreferences(onboardingComplete: true)
        legacyDefaults.set(try JSONEncoder().encode(expected), forKey: PreferencesRepository.legacyKey)

        #expect(
            PreferencesRepository(defaults: defaults, legacyDefaults: legacyDefaults).load() == expected
        )
    }

    @Test("Claude and Codex adapters decode their own identity")
    func agentAdaptersDecodeTheirIdentity() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "hook_event_name": "SessionStart",
                "session_id": "session",
                "cwd": "/tmp/project"
            ]
        )
        let terminal = TerminalContext(kind: .terminal, tty: "/dev/ttys001")
        let claude = try ClaudeLifecycleAdapter().decode(
            data: data,
            terminal: terminal,
            token: "token"
        )
        let codex = try CodexLifecycleAdapter().decode(
            data: data,
            terminal: terminal,
            token: "token"
        )
        #expect(claude.agent == .claude)
        #expect(codex.agent == .codex)
        #expect(claude.event.sessionID == codex.event.sessionID)
    }

    @Test("A fake terminal adapter delivers a reply only to the chosen route")
    func fakeTerminalAdapterRoutesOneSession() throws {
        let fake = FakeTerminalAdapter()
        let terminalSession = AgentSession(
            agent: .claude,
            agentSessionID: "terminal-session",
            cwd: "/tmp/one",
            terminal: TerminalContext(kind: .terminal, tty: "/dev/ttys001")
        )
        let iTermSession = AgentSession(
            agent: .codex,
            agentSessionID: "iterm-session",
            cwd: "/tmp/two",
            terminal: TerminalContext(
                kind: .iTerm,
                iTermSessionID: "w0t0p0:TARGET",
                tty: "/dev/ttys002"
            )
        )

        fake.send(text: "continue", to: iTermSession) { _ in }
        #expect(fake.deliveries.count == 1)
        #expect(fake.deliveries.first?.text == "continue")
        #expect(
            fake.deliveries.first?.route
                == .iTerm(uniqueID: "TARGET", tty: "/dev/ttys002")
        )
        let otherRoute = try TerminalRouteResolver.resolve(terminalSession.terminal)
        #expect(fake.deliveries.first?.route != otherRoute)
    }
}

private final class FakeTerminalAdapter: TerminalSessionControlling {
    struct Delivery {
        let text: String
        let route: TerminalSessionRoute
    }

    private(set) var focused: [TerminalSessionRoute] = []
    private(set) var deliveries: [Delivery] = []

    func focus(
        session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            focused.append(try TerminalRouteResolver.resolve(session.terminal))
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func send(
        text: String,
        to session: AgentSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            deliveries.append(
                Delivery(
                    text: text,
                    route: try TerminalRouteResolver.resolve(session.terminal)
                )
            )
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }
}
