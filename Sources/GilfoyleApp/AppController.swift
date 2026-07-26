import AppKit
import Combine
import Foundation
import GilfoyleCore
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    let sessionStore = SessionStore()
    let preferences = AppPreferences()
    let permissionManager = PermissionManager()
    let launchAtLoginManager = LaunchAtLoginManager()

    @Published var isExpanded = false
    @Published private(set) var calloutSessionID: String?
    @Published private(set) var focusedSessionID: String?
    @Published var bridgeError: String?
    @Published var transientMessage: String?
    @Published private(set) var claudeIntegration: IntegrationStatus?
    @Published private(set) var codexIntegration: IntegrationStatus?
    @Published private(set) var environment = EnvironmentDetector.detect()
    private var calloutAccessoryHeight: CGFloat = 0

    var preferredCalloutBodyHeight: CGFloat {
        guard let sessionID = calloutSessionID,
              let preview = sessionStore.session(id: sessionID)?.lastResponsePreview,
              !preview.isEmpty
        else { return 256 + calloutAccessoryHeight }
        let visualLines = preview.components(separatedBy: .newlines).reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / 90)))
        }
        let responseHeight = min(250, max(38, 22 + CGFloat(visualLines) * 17))
        return min(532, max(256, 218 + responseHeight) + calloutAccessoryHeight)
    }

    private let socketServer = UnixSocketServer()
    private let terminalAutomation: any TerminalSessionControlling
    private let processMonitor = SessionProcessMonitor()
    private let agentProcessDiscovery = CodingAgentProcessDiscovery()
    private let shortcutManager = GlobalShortcutManager()
    private let responseBroker = InteractionResponseBroker()
    private var cancellables: Set<AnyCancellable> = []
    private var calloutDismissWorkItem: DispatchWorkItem?
    private var queuedReplies: [String: [String]] = [:]

    private var panelController: NotchPanelController?
    private var settingsWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?

    lazy var integrationInstaller = IntegrationInstaller(helperURL: helperExecutableURL)

    init(terminalAutomation: any TerminalSessionControlling = TerminalAutomationController()) {
        self.terminalAutomation = terminalAutomation

        preferences.$shortcut
            .sink { [weak self] shortcut in
                try? self?.shortcutManager.register(shortcut)
            }
            .store(in: &cancellables)

        shortcutManager.action = { [weak self] in
            self?.togglePanel()
        }
    }

    func start() {
        do {
            let token = try IPCTokenStore.ensure()
            try socketServer.start(token: token) { [weak self] request, respond in
                DispatchQueue.main.async {
                    self?.handle(request: request, respond: respond)
                }
            }
            bridgeError = nil
        } catch {
            bridgeError = error.localizedDescription
        }

        panelController = NotchPanelController(controller: self)
        panelController?.showCompact()
        let existingProcesses = agentProcessDiscovery.discoverNow()
        _ = sessionStore.discover(existingProcesses)
        agentProcessDiscovery.start { [weak self] sessions in
            DispatchQueue.main.async {
                guard let self else { return }
                let completed = self.sessionStore.discover(sessions)
                // A local Codex rollout can finish without emitting a Stop
                // hook. The process scan is the fallback that still turns
                // that completion into the visible Anton callout.
                if let sessionID = completed.last {
                    self.showCompletionCallout(sessionID: sessionID)
                }
            }
        }
        refreshEnvironment()
        // Older builds also registered SMAppService in addition to Anton's
        // launchd supervisor. Keep a single startup owner to avoid two
        // processes racing and bouncing the overlay at login.
        if launchAtLoginManager.isEnabled {
            launchAtLoginManager.disableLegacyRegistrationIfNeeded()
        }
        refreshIntegrations()
        if !preferences.onboardingComplete {
            showOnboarding()
        }
        runVisualValidationIfRequested()
    }

    func stop() {
        responseBroker.cancelAll(
            message: "Anton closed before the request was answered."
        )
        processMonitor.stopAll()
        agentProcessDiscovery.stop()
        socketServer.stop()
    }

    func togglePanel() {
        if isExpanded {
            collapsePanel()
        } else {
            showSessionBoard()
        }
    }

    func setExpanded(_ expanded: Bool) {
        if !expanded {
            cancelCalloutDismiss()
        }
        calloutSessionID = nil
        calloutAccessoryHeight = 0
        focusedSessionID = nil
        isExpanded = expanded
        panelController?.setExpanded(expanded)
    }

    func collapsePanel() {
        setExpanded(false)
    }

    func showSessionBoard(focusing sessionID: String? = nil) {
        cancelCalloutDismiss()
        calloutSessionID = nil
        calloutAccessoryHeight = 0
        focusedSessionID = sessionID
        isExpanded = true
        panelController?.setExpanded(true)
    }

    func showCompletionCallout(sessionID: String) {
        presentCallout(sessionID: sessionID)
    }

    func showUrgentCallout(sessionID: String) {
        // An approval or question is actionable work, not a toast. Keep it
        // visible until the user answers, opens the board, or presses X.
        presentCallout(sessionID: sessionID)
    }

    func dismissCallout() {
        cancelCalloutDismiss()
        calloutSessionID = nil
        calloutAccessoryHeight = 0
        focusedSessionID = nil
        isExpanded = false
        panelController?.setExpanded(false)
    }

    private func presentCallout(sessionID: String, dismissAfter: TimeInterval? = nil) {
        cancelCalloutDismiss()
        calloutAccessoryHeight = 0
        calloutSessionID = sessionID
        focusedSessionID = nil
        isExpanded = true
        panelController?.setExpanded(true)
        guard let dismissAfter else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard self?.calloutSessionID == sessionID else { return }
            self?.dismissCallout()
        }
        calloutDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: workItem)
    }

    func setCalloutHasAttachments(_ hasAttachments: Bool) {
        guard calloutSessionID != nil else { return }
        let nextHeight: CGFloat = hasAttachments ? 30 : 0
        guard calloutAccessoryHeight != nextHeight else { return }
        calloutAccessoryHeight = nextHeight
        panelController?.setExpanded(true)
    }

    func replyFromCallout(sessionID: String) {
        sessionStore.acknowledgeCompletion(sessionID: sessionID)
        showSessionBoard(focusing: sessionID)
        beginExplicitReply()
    }

    /// The panel stays non-key while it is merely visible. A direct click in
    /// an editor is an explicit request to type, so it may safely become key.
    func beginExplicitReply() {
        panelController?.focusForExplicitReply()
    }

    /// The Anton notch deliberately sits above normal windows. A native open
    /// panel must therefore temporarily replace it, otherwise the picker can
    /// appear behind the overlay and look as if Attach File did nothing.
    func chooseAttachments(completion: @escaping ([URL]) -> Void) {
        panelController?.hideForSystemModal()
        AttachmentPicker.present { [weak self] urls in
            guard let self else { return }
            self.panelController?.restoreAfterSystemModal()
            completion(urls)
        }
    }

    func focus(sessionID: String) {
        guard let session = sessionStore.session(id: sessionID) else { return }
        sessionStore.acknowledgeCompletion(sessionID: sessionID)
        terminalAutomation.focus(session: session) { [weak self] result in
            if case .failure(let error) = result {
                self?.showMessage(error.localizedDescription)
            }
        }
    }

    /// Copies the exact response that Anton is displaying. This is local-only
    /// and deliberately does not focus the originating terminal.
    func copyResponse(sessionID: String) {
        guard let response = sessionStore.session(id: sessionID)?.lastResponsePreview,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showMessage("There is no response to copy yet.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(response, forType: .string)
        showMessage("Response copied.")
    }

    func sendReply(
        _ text: String,
        to sessionID: String,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = sessionStore.session(id: sessionID) else {
            completion(false)
            return
        }
        terminalAutomation.send(text: trimmed, to: session) { [weak self] result in
            switch result {
            case .success:
                self?.sessionStore.markWorking(sessionID: sessionID)
                self?.collapsePanel()
                completion(true)
            case .failure(let error):
                self?.showMessage(error.localizedDescription)
                completion(false)
            }
        }
    }

    /// Never writes into a terminal while an agent is using that TTY. The
    /// message is sent silently as soon as the current turn finishes.
    func queueReply(_ text: String, to sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sessionStore.session(id: sessionID) != nil else { return }
        queuedReplies[sessionID, default: []].append(trimmed)
        showMessage("Message queued for the next turn.")
    }

    func allow(interactionID: String, sessionID: String) {
        resolve(
            interactionID: interactionID,
            sessionID: sessionID,
            response: BridgeResponse(requestID: interactionID, decision: .allow)
        )
    }

    func deny(interactionID: String, sessionID: String) {
        resolve(
            interactionID: interactionID,
            sessionID: sessionID,
            response: BridgeResponse(
                requestID: interactionID,
                decision: .deny,
                message: "Denied by the user in Anton."
            )
        )
    }

    func answer(
        interactionID: String,
        sessionID: String,
        answers: [String: String]
    ) {
        let payload = JSONValue.object([
            "answers": .object(answers.mapValues(JSONValue.string))
        ])
        resolve(
            interactionID: interactionID,
            sessionID: sessionID,
            response: BridgeResponse(
                requestID: interactionID,
                decision: .answer,
                payload: payload
            )
        )
    }

    func cancel(interactionID: String, sessionID: String) {
        resolve(
            interactionID: interactionID,
            sessionID: sessionID,
            response: BridgeResponse(
                requestID: interactionID,
                decision: .cancel,
                message: "Cancelled by the user in Anton."
            )
        )
    }

    func dismiss(sessionID: String) {
        sessionStore.dismiss(sessionID: sessionID)
    }

    func updateShortcut(_ shortcut: ShortcutConfiguration) {
        do {
            try shortcutManager.register(shortcut)
            preferences.shortcut = shortcut
        } catch {
            showMessage(error.localizedDescription)
        }
    }

    func refreshEnvironment() {
        environment = EnvironmentDetector.detect()
        permissionManager.refresh()
        launchAtLoginManager.refresh()
    }

    func refreshIntegrations() {
        claudeIntegration = integrationInstaller.status(for: .claude)
        codexIntegration = integrationInstaller.status(for: .codex)
    }

    func installIntegration(_ agent: AgentKind) {
        do {
            _ = try agent == .claude
                ? integrationInstaller.installClaude()
                : integrationInstaller.installCodex()
            refreshIntegrations()
            showMessage(
                agent == .codex
                    ? "Codex hooks installed. Run /hooks once in Codex to review and trust them."
                    : "Claude Code hooks installed."
            )
        } catch {
            showMessage(error.localizedDescription)
        }
    }

    func removeIntegration(_ agent: AgentKind) {
        do {
            _ = try agent == .claude
                ? integrationInstaller.removeClaude()
                : integrationInstaller.removeCodex()
            refreshIntegrations()
            showMessage("\(agent.displayName) integration removed.")
        } catch {
            showMessage(error.localizedDescription)
        }
    }

    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = makeWindowController(
                title: "Anton Settings",
                size: NSSize(width: 640, height: 670),
                content: SettingsView(controller: self)
            )
        }
        present(settingsWindowController)
    }

    func showOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = makeWindowController(
                title: "Welcome to Anton",
                size: NSSize(width: 720, height: 690),
                content: OnboardingView(controller: self)
            )
        }
        present(onboardingWindowController)
    }

    func completeOnboarding() {
        preferences.onboardingComplete = true
        onboardingWindowController?.close()
        onboardingWindowController = nil
        setExpanded(true)
    }

    private func handle(
        request: BridgeRequest,
        respond: @escaping UnixSocketServer.ResponseHandler
    ) {
        let reduction = sessionStore.ingest(request)
        let metadata = LocalAgentSessionMetadata.titleAndModel(
            agent: reduction.session.agent,
            sessionID: reduction.session.agentSessionID
        )
        sessionStore.enrich(
            sessionID: reduction.session.id,
            name: metadata.name,
            model: metadata.model
        )
        if reduction.session.state == .disconnected {
            processMonitor.stopWatching(sessionID: reduction.session.id)
        } else {
            processMonitor.watch(
                sessionID: reduction.session.id,
                processID: reduction.session.terminal.processID
            ) { [weak self] in
                self?.agentProcessExited(sessionID: reduction.session.id)
            }
        }
        if reduction.requiresInteractiveResponse {
            responseBroker.register(requestID: request.requestID, handler: respond)
            showUrgentCallout(sessionID: reduction.session.id)
        } else {
            respond(
                BridgeResponse(
                    requestID: request.requestID,
                    decision: .acknowledge
                )
            )
            if reduction.didCompleteMainTurn {
                deliverQueuedReplyIfNeeded(to: reduction.session)
            }
        }
    }

    private func deliverQueuedReplyIfNeeded(to session: AgentSession) {
        guard var queue = queuedReplies[session.id], !queue.isEmpty else {
            showCompletionCallout(sessionID: session.id)
            return
        }
        let reply = queue.removeFirst()
        queuedReplies[session.id] = queue.isEmpty ? nil : queue
        terminalAutomation.send(text: reply, to: session) { [weak self] result in
            switch result {
            case .success:
                self?.sessionStore.markWorking(
                    sessionID: session.id,
                    activity: "Queued message sent"
                )
            case .failure(let error):
                self?.queuedReplies[session.id, default: []].insert(reply, at: 0)
                self?.showMessage(error.localizedDescription)
            }
        }
    }

    private func cancelCalloutDismiss() {
        calloutDismissWorkItem?.cancel()
        calloutDismissWorkItem = nil
    }

    private func resolve(
        interactionID: String,
        sessionID: String,
        response: BridgeResponse
    ) {
        guard responseBroker.resolve(requestID: interactionID, response: response) else {
            showMessage("This request is no longer waiting for a response.")
            return
        }
        sessionStore.resolveInteraction(sessionID: sessionID)
    }

    private func agentProcessExited(sessionID: String) {
        if let interactionID = sessionStore.session(id: sessionID)?.interaction?.id {
            _ = responseBroker.resolve(
                requestID: interactionID,
                response: BridgeResponse(
                    requestID: interactionID,
                    decision: .cancel,
                    message: "The agent process exited."
                )
            )
        }
        sessionStore.markDisconnected(sessionID: sessionID)
    }

    private func showMessage(_ message: String) {
        transientMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.transientMessage == message {
                self?.transientMessage = nil
            }
        }
    }

    private var helperExecutableURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("anton-hook")
        }
        return Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("anton-hook")
            ?? URL(fileURLWithPath: "anton-hook")
    }

    private func makeWindowController<Content: View>(
        title: String,
        size: NSSize,
        content: Content
    ) -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.backgroundColor = NSColor(red: 0.035, green: 0.04, blue: 0.05, alpha: 1)
        window.contentViewController = NSHostingController(rootView: content)
        window.center()
        return NSWindowController(window: window)
    }

    private func present(_ controller: NSWindowController?) {
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.orderFrontRegardless()
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    private func runVisualValidationIfRequested() {
        guard
            let path = ProcessInfo.processInfo.environment["ANTON_SNAPSHOT_DIR"],
            !path.isEmpty
        else {
            return
        }

        let destination = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.capture(
                window: self.panelController?.window,
                to: destination.appendingPathComponent("01-compact.png")
            )
            self.showOnboarding()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.capture(
                    window: self.onboardingWindowController?.window,
                    to: destination.appendingPathComponent("02-onboarding.png")
                )

                self.seedVisualValidationSessions()
                self.showCompletionCallout(sessionID: "claude:visual-finished")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    self.capture(
                        window: self.panelController?.window,
                        to: destination.appendingPathComponent("03-callout.png")
                    )

                    self.showSessionBoard()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self else { return }
                        self.capture(
                            window: self.panelController?.window,
                            to: destination.appendingPathComponent("04-session-board.png")
                        )

                        self.showSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                            guard let self else { return }
                            self.capture(
                                window: self.settingsWindowController?.window,
                                to: destination.appendingPathComponent("05-settings.png")
                            )
                        }
                    }
                }
            }
        }
    }

    private func seedVisualValidationSessions() {
        let now = Date()
        _ = sessionStore.ingest(
            BridgeRequest(
                token: "visual-validation",
                requestID: "visual-approval",
                agent: .claude,
                event: HookEventPayload(
                    name: "PermissionRequest",
                    sessionID: "visual-claude",
                    cwd: "/Users/example/checkout-service",
                    model: "Claude Sonnet",
                    toolName: "Bash",
                    toolInput: .object([
                        "command": .string("swift test"),
                        "description": .string("Run the checkout test suite")
                    ])
                ),
                terminal: TerminalContext(
                    kind: .terminal,
                    terminalSessionID: "visual-terminal",
                    tty: "/dev/ttys004"
                ),
                sentAt: now
            ),
            now: now.addingTimeInterval(-148)
        )
        _ = sessionStore.ingest(
            BridgeRequest(
                token: "visual-validation",
                requestID: "visual-question",
                agent: .codex,
                event: HookEventPayload(
                    name: "PreToolUse",
                    sessionID: "visual-codex",
                    cwd: "/Users/example/storefront",
                    model: "GPT-5",
                    toolName: "request_user_input",
                    toolInput: .object([
                        "questions": .array([
                            .object([
                                "id": .string("pagination"),
                                "header": .string("Pagination"),
                                "question": .string("Which pagination style should we ship?"),
                                "options": .array([
                                    .object([
                                        "label": .string("Cursor"),
                                        "description": .string("Stable for changing order history")
                                    ]),
                                    .object([
                                        "label": .string("Pages"),
                                        "description": .string("Simple numbered navigation")
                                    ])
                                ])
                            ])
                        ])
                    ])
                ),
                terminal: TerminalContext(
                    kind: .iTerm,
                    iTermSessionID: "w0t1p0:VISUAL",
                    tty: "/dev/ttys006"
                ),
                sentAt: now
            ),
            now: now.addingTimeInterval(-71)
        )
        _ = sessionStore.ingest(
            BridgeRequest(
                token: "visual-validation",
                requestID: "visual-finished",
                agent: .claude,
                event: HookEventPayload(
                    name: "Stop",
                    sessionID: "visual-finished",
                    cwd: "/Users/example/billing-service",
                    model: "Claude Sonnet",
                    lastAssistantMessage: "Billing empty state is polished and the focused tests pass."
                ),
                terminal: TerminalContext(
                    kind: .terminal,
                    terminalSessionID: "visual-terminal-2",
                    tty: "/dev/ttys008"
                ),
                sentAt: now
            ),
            now: now.addingTimeInterval(-24)
        )
    }

    private func capture(window: NSWindow?, to destination: URL) {
        guard let view = window?.contentView, view.bounds.width > 0, view.bounds.height > 0 else {
            return
        }
        view.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: destination, options: .atomic)
    }

}
