import AppKit
import Combine
import Foundation
import GilfoyleCore
import SwiftUI

private struct PendingAgentLaunch {
    let token: String
    let provisionalSessionID: String
    let agent: AgentKind
    let sessionName: String?
    let initialPrompt: String
    let startedAt: Date
    let plan: AgentSessionLaunchPlan
    var attempt: Int
    var terminal: TerminalContext
}

@MainActor
final class AppController: ObservableObject {
    let sessionStore = SessionStore()
    let preferences = AppPreferences()
    let permissionManager = PermissionManager()

    @Published var isExpanded = false
    @Published private(set) var calloutSessionID: String?
    @Published private(set) var focusedSessionID: String?
    @Published var bridgeError: String?
    @Published var transientMessage: String?
    @Published private(set) var claudeIntegration: IntegrationStatus?
    @Published private(set) var codexIntegration: IntegrationStatus?
    @Published private(set) var environment = EnvironmentDetector.detect()
    @Published private(set) var pendingCalloutCount = 0
    @Published private(set) var compactCameraWidth: CGFloat = 150
    @Published private(set) var endingSessionIDs: Set<String> = []
    @Published var sessionLauncherMode: AgentSessionLaunchMode?
    @Published private(set) var resumableSessions: [ResumableAgentSession] = []
    @Published private(set) var isLoadingSessionCatalog = false
    @Published private(set) var sessionCatalogError: String?
    private var calloutAccessoryHeight: CGFloat = 0
    let compactAntonWingWidth: CGFloat = 55

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

    var compactVisibleSessionCount: Int {
        let count = sessionStore.sessions.count
        return count >= 6 ? 4 : count
    }

    func updateCompactCameraWidth(_ width: CGFloat) {
        guard abs(compactCameraWidth - width) > 0.5 else { return }
        compactCameraWidth = width
    }

    private let socketServer = UnixSocketServer()
    private let terminalAutomation: any TerminalSessionControlling
    private let terminalLauncher: any TerminalSessionLaunching
    private let sessionTerminator: any AgentSessionTerminating
    private let processMonitor = SessionProcessMonitor()
    private let agentProcessDiscovery = CodingAgentProcessDiscovery()
    private let terminationQueue = DispatchQueue(
        label: "com.augustalabs.anton.session-termination",
        qos: .userInitiated
    )
    private let shortcutManager = GlobalShortcutManager()
    private let responseBroker = InteractionResponseBroker()
    private let sessionCatalog = LocalSessionCatalog()
    private let sessionCatalogQueue = DispatchQueue(
        label: "com.augustalabs.anton.session-catalog",
        qos: .userInitiated
    )
    private var cancellables: Set<AnyCancellable> = []
    private var pendingCallouts = PendingCalloutQueue()
    private var queuedReplies: [String: [String]] = [:]
    private var pendingAgentLaunches: [String: PendingAgentLaunch] = [:]

    private var panelController: NotchPanelController?
    private var settingsWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?

    lazy var integrationInstaller = IntegrationInstaller(helperURL: helperExecutableURL)

    init(
        terminalAutomation: any TerminalSessionControlling = TerminalAutomationController(),
        terminalLauncher: any TerminalSessionLaunching = TerminalAutomationController(),
        sessionTerminator: any AgentSessionTerminating = AgentSessionTerminator()
    ) {
        self.terminalAutomation = terminalAutomation
        self.terminalLauncher = terminalLauncher
        self.sessionTerminator = sessionTerminator

        preferences.$shortcut
            .sink { [weak self] shortcut in
                try? self?.shortcutManager.register(shortcut, for: .toggle)
            }
            .store(in: &cancellables)

        try? shortcutManager.register(
            ShortcutConfiguration(
                keyCode: 45,
                command: true,
                option: true,
                control: false,
                shift: false
            ),
            for: .newSession
        )
        try? shortcutManager.register(
            ShortcutConfiguration(
                keyCode: 15,
                command: true,
                option: true,
                control: false,
                shift: false
            ),
            for: .resumeSession
        )
        try? shortcutManager.register(
            ShortcutConfiguration(
                keyCode: 15,
                command: true,
                option: true,
                control: false,
                shift: true
            ),
            for: .resumeLatest
        )

        shortcutManager.action = { [weak self] action in
            switch action {
            case .toggle:
                self?.togglePanel()
            case .newSession:
                self?.showSessionLauncher(mode: .new)
            case .resumeSession:
                self?.showSessionLauncher(mode: .resume)
            case .resumeLatest:
                self?.resumeLatestSession()
            }
        }

        sessionStore.$sessions
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, !self.isExpanded else { return }
                self.panelController?.refreshCompactFrame()
            }
            .store(in: &cancellables)
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
        let initialDiscovery = sessionStore.discover(existingProcesses)
        watchDiscoveredProcesses(existingProcesses)
        closeExitedTerminalSessions(initialDiscovery.exitedSessions)
        agentProcessDiscovery.start { [weak self] sessions in
            DispatchQueue.main.async {
                guard let self else { return }
                let discovery = self.sessionStore.discover(sessions)
                self.watchDiscoveredProcesses(sessions)
                self.closeExitedTerminalSessions(discovery.exitedSessions)
                // A local Codex rollout can finish without emitting a Stop
                // hook. The process scan is the fallback that still turns
                // that completion into the visible Anton callout.
                for sessionID in discovery.completedSessionIDs {
                    self.showCompletionCallout(sessionID: sessionID)
                }
            }
        }
        refreshEnvironment()
        // Older builds also registered SMAppService in addition to Anton's
        // launchd supervisor. Keep a single startup owner to avoid two
        // processes racing and bouncing the overlay at login.
        LaunchAtLoginManager.disableLegacyRegistrationIfNeeded()
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
        calloutSessionID = nil
        calloutAccessoryHeight = 0
        focusedSessionID = nil
        if !expanded {
            sessionLauncherMode = nil
        }
        isExpanded = expanded
        panelController?.setExpanded(expanded)
    }

    func collapsePanel() {
        if calloutSessionID != nil, presentNextPendingCallout() {
            return
        }
        setExpanded(false)
    }

    func showSessionBoard(focusing sessionID: String? = nil) {
        pendingCallouts.removeAll()
        pendingCalloutCount = 0
        calloutSessionID = nil
        calloutAccessoryHeight = 0
        sessionLauncherMode = nil
        focusedSessionID = sessionID
        isExpanded = true
        panelController?.setExpanded(true)
    }

    func showSessionLauncher(mode: AgentSessionLaunchMode = .new) {
        pendingCallouts.removeAll()
        pendingCalloutCount = 0
        calloutSessionID = nil
        calloutAccessoryHeight = 0
        focusedSessionID = nil
        sessionLauncherMode = mode
        isExpanded = true
        panelController?.setExpanded(true)
        panelController?.focusForExplicitReply()
        refreshSessionCatalog()
    }

    func closeSessionLauncher() {
        sessionLauncherMode = nil
        showSessionBoard()
    }

    var suggestedWorkspace: String {
        preferences.lastLaunchWorkspace.flatMap { workspace in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: workspace,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue ? workspace : nil
        }
            ?? sessionStore.sessions.first?.cwd
            ?? resumableSessions.first(where: { !$0.cwd.isEmpty })?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var preferredLaunchAgent: AgentKind {
        if let preferred = preferences.lastLaunchAgent,
           executablePath(for: preferred) != nil
        {
            return preferred
        }
        return environment.claudePath != nil ? .claude : .codex
    }

    var availableLaunchTerminals: [TerminalKind] {
        var result: [TerminalKind] = []
        if environment.terminalInstalled { result.append(.terminal) }
        if environment.iTermInstalled { result.append(.iTerm) }
        return result
    }

    var defaultLaunchTerminal: TerminalKind {
        if let preferred = preferences.lastLaunchTerminal,
           availableLaunchTerminals.contains(preferred)
        {
            return preferred
        }
        return availableLaunchTerminals.first ?? .terminal
    }

    func chooseWorkspace(completion: @escaping (String?) -> Void) {
        panelController?.hideForSystemModal()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose workspace"
        panel.directoryURL = URL(fileURLWithPath: suggestedWorkspace, isDirectory: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.panelController?.restoreAfterSystemModal()
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    func refreshSessionCatalog() {
        guard !isLoadingSessionCatalog else { return }
        isLoadingSessionCatalog = true
        sessionCatalogError = nil
        let catalog = sessionCatalog
        sessionCatalogQueue.async { [weak self] in
            let loaded = catalog.load()
            DispatchQueue.main.async {
                guard let self else { return }
                let running = Set(
                    self.sessionStore.sessions.map {
                        "\($0.agent.rawValue):\($0.agentSessionID)"
                    }
                )
                self.resumableSessions = loaded.map { candidate in
                    var candidate = candidate
                    candidate.isRunning = running.contains(candidate.id)
                    return candidate
                }
                self.isLoadingSessionCatalog = false
                if loaded.isEmpty {
                    self.sessionCatalogError = "No saved Claude or Codex sessions were found."
                }
            }
        }
    }

    func startAgentSession(
        agent: AgentKind,
        mode: AgentSessionLaunchMode,
        workspace: String,
        name: String,
        initialPrompt: String,
        terminalKind: TerminalKind,
        candidate: ResumableAgentSession? = nil
    ) {
        if let candidate, candidate.isRunning,
           let running = sessionStore.sessions.first(where: {
               $0.agent == candidate.agent
                   && $0.agentSessionID == candidate.sessionID
           })
        {
            showSessionBoard(focusing: running.id)
            showMessage("That session is already running.")
            return
        }

        let resolvedWorkspace = mode == .new ? workspace : (candidate?.cwd ?? workspace)
        var isDirectory: ObjCBool = false
        guard
            !resolvedWorkspace.isEmpty,
            FileManager.default.fileExists(
                atPath: resolvedWorkspace,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            sessionCatalogError = "The selected workspace no longer exists."
            return
        }
        guard availableLaunchTerminals.contains(terminalKind) else {
            sessionCatalogError = AgentSessionLaunchError.unsupportedTerminal.localizedDescription
            return
        }
        let executablePath = executablePath(for: agent)
        guard let executablePath else {
            sessionCatalogError = "\(agent.displayName) is not installed or could not be found."
            return
        }
        let normalizedName = normalizedSessionName(name)
        preferences.lastLaunchAgent = agent
        preferences.lastLaunchWorkspace = resolvedWorkspace
        preferences.lastLaunchTerminal = terminalKind

        let token = UUID().uuidString.lowercased()
        let plan = AgentSessionLaunchPlan(
            launchToken: token,
            agent: agent,
            mode: mode,
            executablePath: executablePath,
            cwd: resolvedWorkspace,
            priorSessionID: candidate?.sessionID,
            sessionName: normalizedName,
            terminalKind: terminalKind
        )
        do {
            _ = try AgentLaunchCommandBuilder.command(for: plan)
        } catch {
            sessionCatalogError = error.localizedDescription
            return
        }

        var provisional = AgentSession(
            agent: agent,
            agentSessionID: "launch-\(token)",
            cwd: resolvedWorkspace,
            sessionName: normalizedName
                ?? candidate?.explicitName
                ?? candidate?.gitBranch,
            model: candidate?.model,
            state: .working,
            terminal: TerminalContext(kind: terminalKind)
        )
        provisional.currentActivity = mode == .new
            ? "Opening terminal"
            : mode == .resume ? "Opening session" : "Opening fork"
        sessionStore.addProvisional(provisional)
        pendingAgentLaunches[token] = PendingAgentLaunch(
            token: token,
            provisionalSessionID: provisional.id,
            agent: agent,
            sessionName: normalizedName,
            initialPrompt: initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            startedAt: Date(),
            plan: plan,
            attempt: 1,
            terminal: provisional.terminal
        )
        showSessionBoard(focusing: provisional.id)
        launchPendingAgent(token: token)
    }

    private func launchPendingAgent(token: String) {
        guard let pending = pendingAgentLaunches[token] else { return }
        let attempt = pending.attempt
        terminalLauncher.launch(plan: pending.plan) { [weak self] result in
            guard
                let self,
                var current = self.pendingAgentLaunches[token],
                current.attempt == attempt
            else {
                return
            }
            switch result {
            case .success(let terminal):
                current.terminal = terminal
                self.pendingAgentLaunches[token] = current
                self.sessionStore.updateLaunchTerminal(
                    sessionID: current.provisionalSessionID,
                    terminal: terminal
                )
                self.scheduleLaunchTimeout(token: token, attempt: attempt)
            case .failure(let error):
                self.sessionStore.markLaunchFailed(
                    sessionID: current.provisionalSessionID,
                    message: "Could not open \(current.agent.displayName)"
                )
                self.showUrgentCallout(sessionID: current.provisionalSessionID)
                self.showMessage(error.localizedDescription)
            }
        }
    }

    func canRetryLaunch(sessionID: String) -> Bool {
        pendingAgentLaunches.values.contains { pending in
            pending.provisionalSessionID == sessionID
                && pending.terminal.tty == nil
                && pending.terminal.iTermSessionID == nil
        }
    }

    func retryLaunch(sessionID: String) {
        guard let entry = pendingAgentLaunches.first(where: {
            $0.value.provisionalSessionID == sessionID
        }) else {
            showMessage("This launch can no longer be retried.")
            return
        }
        var pending = entry.value
        guard pending.terminal.tty == nil,
              pending.terminal.iTermSessionID == nil
        else {
            showMessage("Open the existing terminal session to finish setup.")
            return
        }
        pending.attempt += 1
        pendingAgentLaunches[entry.key] = pending
        sessionStore.markLaunchRetrying(sessionID: sessionID)
        launchPendingAgent(token: entry.key)
    }

    func resumeLatestSession() {
        let catalog = sessionCatalog
        sessionCatalogQueue.async { [weak self] in
            let sessions = catalog.load()
            DispatchQueue.main.async {
                guard let self else { return }
                let candidate = sessions.first(where: {
                    !$0.cwd.isEmpty
                        && FileManager.default.fileExists(atPath: $0.cwd)
                })
                guard let candidate else {
                    self.showSessionLauncher(mode: .resume)
                    self.showMessage("No resumable session was found.")
                    return
                }
                var current = candidate
                current.isRunning = self.sessionStore.sessions.contains {
                    $0.agent == candidate.agent
                        && $0.agentSessionID == candidate.sessionID
                }
                self.startAgentSession(
                    agent: current.agent,
                    mode: .resume,
                    workspace: current.cwd,
                    name: "",
                    initialPrompt: "",
                    terminalKind: self.defaultLaunchTerminal,
                    candidate: current
                )
            }
        }
    }

    private func scheduleLaunchTimeout(token: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard
                let self,
                let pending = self.pendingAgentLaunches[token],
                pending.attempt == attempt
            else {
                return
            }
            self.sessionStore.markLaunchFailed(
                sessionID: pending.provisionalSessionID,
                message: "Agent startup needs attention"
            )
            self.showUrgentCallout(sessionID: pending.provisionalSessionID)
            self.showMessage(
                "The terminal opened, but \(pending.agent.displayName) did not report SessionStart."
            )
            // Keep the launch token while its card exists. A delayed trust or
            // setup flow can still upgrade this exact provisional session.
        }
    }

    private func normalizedSessionName(_ name: String) -> String? {
        let value = name
            .components(separatedBy: .newlines)
            .first?
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : String(value.prefix(96))
    }

    private func executablePath(for agent: AgentKind) -> String? {
        agent == .claude ? environment.claudePath : environment.codexPath
    }

    func showCompletionCallout(sessionID: String) {
        presentOrQueueCallout(sessionID: sessionID, urgent: false)
    }

    func showUrgentCallout(sessionID: String) {
        // An approval or question is actionable work, not a toast. Keep it
        // visible until the user answers, opens the board, or presses X.
        presentOrQueueCallout(sessionID: sessionID, urgent: true)
    }

    func dismissCallout() {
        collapsePanel()
    }

    private func presentOrQueueCallout(sessionID: String, urgent: Bool) {
        guard sessionStore.session(id: sessionID) != nil else { return }
        guard calloutSessionID != sessionID else { return }
        if calloutSessionID != nil {
            pendingCallouts.enqueue(sessionID: sessionID, urgent: urgent)
            pendingCalloutCount = pendingCallouts.count
            return
        }
        // The expanded board already exposes every live session. The launcher
        // is also an intentional modal workflow, so a simultaneous completion
        // never replaces it or steals keyboard focus.
        guard !isExpanded else { return }
        presentCallout(sessionID: sessionID)
    }

    private func presentNextPendingCallout() -> Bool {
        while let sessionID = pendingCallouts.popFirst() {
            pendingCalloutCount = pendingCallouts.count
            guard let session = sessionStore.session(id: sessionID),
                  [.finished, .needsApproval, .hasQuestion, .error].contains(session.state)
            else {
                continue
            }
            presentCallout(sessionID: sessionID)
            return true
        }
        return false
    }

    private func presentCallout(sessionID: String) {
        calloutAccessoryHeight = 0
        calloutSessionID = sessionID
        focusedSessionID = nil
        isExpanded = true
        panelController?.setExpanded(true)
    }

    func setCalloutHasAttachments(_ hasAttachments: Bool) {
        guard calloutSessionID != nil else { return }
        let nextHeight: CGFloat = hasAttachments ? 30 : 0
        guard calloutAccessoryHeight != nextHeight else { return }
        calloutAccessoryHeight = nextHeight
        panelController?.setExpanded(true)
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
        terminalAutomation.focus(session: session) { [weak self] result in
            if case .failure(let error) = result {
                self?.showMessage(error.localizedDescription)
            }
        }
    }

    func endSession(sessionID: String) {
        guard
            !endingSessionIDs.contains(sessionID),
            let session = sessionStore.session(id: sessionID)
        else {
            return
        }
        endingSessionIDs.insert(sessionID)
        showMessage("Ending \(session.agent.displayName) session…")
        let terminator = sessionTerminator
        terminationQueue.async { [weak self] in
            let result = Result { try terminator.terminate(session) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.endingSessionIDs.remove(sessionID)
                switch result {
                case .success:
                    self.agentProcessExited(
                        sessionID: sessionID,
                        reason: "Session ended by you"
                    )
                    self.showMessage("Session ended.")
                case .failure(let error):
                    self.showMessage(error.localizedDescription)
                }
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
        collapseAfterSend: Bool = true,
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
                guard let self else {
                    completion(false)
                    return
                }
                let activity = "Submitting prompt"
                let needsAcknowledgement = self.sessionStore.markWorking(
                    sessionID: sessionID,
                    activity: activity
                )
                if collapseAfterSend {
                    self.collapsePanel()
                }
                if needsAcknowledgement {
                    self.ensurePromptStarted(
                        sessionID: sessionID,
                        session: session,
                        expectedActivity: activity
                    )
                }
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
        pendingAgentLaunches = pendingAgentLaunches.filter {
            $0.value.provisionalSessionID != sessionID
        }
        pendingCallouts.remove(sessionID: sessionID)
        pendingCalloutCount = pendingCallouts.count
        if calloutSessionID == sessionID {
            dismissCallout()
        }
        sessionStore.dismiss(sessionID: sessionID)
    }

    func refreshEnvironment() {
        environment = EnvironmentDetector.detect()
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
        let pendingLaunch = matchingPendingLaunch(for: request)
        let reduction = sessionStore.ingest(
            request,
            replacingSessionID: pendingLaunch?.value.provisionalSessionID
        )
        let metadata = LocalAgentSessionMetadata.titleAndModel(
            agent: reduction.session.agent,
            sessionID: reduction.session.agentSessionID
        )
        sessionStore.enrich(
            sessionID: reduction.session.id,
            name: metadata.name,
            model: metadata.model
        )
        if reduction.session.terminal.processID != nil {
            processMonitor.watch(
                sessionID: reduction.session.id,
                processID: reduction.session.terminal.processID
            ) { [weak self] in
                self?.agentProcessExited(sessionID: reduction.session.id)
            }
        } else if reduction.session.state == .disconnected {
            // A lifecycle hook without a recoverable PID cannot be observed
            // further. The stable terminal route still lets us clean it up.
            DispatchQueue.main.async { [weak self] in
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
        if request.event.name == "SessionStart", let pendingLaunch {
            pendingAgentLaunches.removeValue(forKey: pendingLaunch.key)
            completePendingLaunch(
                pendingLaunch.value,
                session: reduction.session
            )
            refreshSessionCatalog()
        }
    }

    private func completePendingLaunch(
        _ pending: PendingAgentLaunch,
        session: AgentSession
    ) {
        // SessionStart is emitted while the CLI is still completing startup.
        // Give the TUI a short moment to expose its composer, then use the
        // exact hook-owned terminal route for naming and prompt delivery.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self else { return }
            if pending.agent == .codex, let name = pending.sessionName {
                self.sessionStore.updateLaunchProgress(
                    sessionID: session.id,
                    activity: "Naming session"
                )
                self.terminalAutomation.send(
                    text: "/rename \(name)",
                    to: session
                ) { [weak self] result in
                    guard let self else { return }
                    if case .failure(let error) = result {
                        self.showMessage(
                            "Session started, but Anton could not apply its name: "
                                + error.localizedDescription
                        )
                    } else {
                        self.sessionStore.enrich(
                            sessionID: session.id,
                            name: name
                        )
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        self.sendInitialPrompt(
                            pending.initialPrompt,
                            to: session
                        )
                    }
                }
            } else {
                self.sendInitialPrompt(pending.initialPrompt, to: session)
            }
        }
    }

    private func sendInitialPrompt(
        _ prompt: String,
        to session: AgentSession
    ) {
        guard !prompt.isEmpty else {
            sessionStore.updateLaunchProgress(
                sessionID: session.id,
                activity: "Ready"
            )
            showMessage("\(session.agent.displayName) session started.")
            return
        }
        sessionStore.updateLaunchProgress(
            sessionID: session.id,
            activity: "Sending initial prompt"
        )
        sendReply(
            prompt,
            to: session.id,
            collapseAfterSend: false
        ) { [weak self] success in
            guard let self, !success else { return }
            self.sessionStore.markLaunchFailed(
                sessionID: session.id,
                message: "Could not send the initial prompt"
            )
            self.showMessage(
                "The agent started, but Anton could not send the initial prompt."
            )
        }
    }

    private func matchingPendingLaunch(
        for request: BridgeRequest
    ) -> (key: String, value: PendingAgentLaunch)? {
        if let token = request.event.metadata["antonLaunchToken"]?.stringValue,
           let pending = pendingAgentLaunches[token] {
            return (token, pending)
        }
        return pendingAgentLaunches.first { _, pending in
            guard pending.agent == request.agent else { return false }
            if let lhs = pending.terminal.iTermSessionID,
               let rhs = request.terminal.iTermSessionID,
               TerminalRouteResolver.normalizedITermIdentifier(lhs)
                    == TerminalRouteResolver.normalizedITermIdentifier(rhs)
            {
                return true
            }
            guard let lhs = pending.terminal.tty,
                  let rhs = request.terminal.tty
            else {
                return false
            }
            return lhs.trimmingCharacters(in: .whitespacesAndNewlines)
                == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
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
                guard let self else { return }
                let activity = "Submitting queued message"
                let needsAcknowledgement = self.sessionStore.markWorking(
                    sessionID: session.id,
                    activity: activity
                )
                if needsAcknowledgement {
                    self.ensurePromptStarted(
                        sessionID: session.id,
                        session: session,
                        expectedActivity: activity
                    )
                }
            case .failure(let error):
                self?.queuedReplies[session.id, default: []].insert(reply, at: 0)
                self?.showMessage(error.localizedDescription)
            }
        }
    }

    /// Terminal.app can occasionally finish the paste without submitting the
    /// TUI composer. If neither the official hook nor local process discovery
    /// observes the new turn, send one background-only Return and verify once
    /// more. The exact TTY/session route is preserved throughout.
    private func ensurePromptStarted(
        sessionID: String,
        session: AgentSession,
        expectedActivity: String
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  let current = self.sessionStore.session(id: sessionID),
                  current.state == .working,
                  current.currentActivity == expectedActivity
            else {
                return
            }
            self.terminalAutomation.submit(session: session) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.sessionStore.markPromptSubmissionUnconfirmed(
                        sessionID: sessionID,
                        expectedActivity: expectedActivity
                    )
                    self.showUrgentCallout(sessionID: sessionID)
                    self.showMessage(error.localizedDescription)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self,
                          let current = self.sessionStore.session(id: sessionID),
                          current.state == .working,
                          current.currentActivity == expectedActivity
                    else {
                        return
                    }
                    self.sessionStore.markPromptSubmissionUnconfirmed(
                        sessionID: sessionID,
                        expectedActivity: expectedActivity
                    )
                    self.showUrgentCallout(sessionID: sessionID)
                    self.showMessage(
                        "The prompt was inserted, but the agent did not acknowledge submission."
                    )
                }
            }
        }
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

    private func agentProcessExited(
        sessionID: String,
        reason: String = "Agent process exited"
    ) {
        guard let session = sessionStore.session(id: sessionID) else { return }
        pendingAgentLaunches = pendingAgentLaunches.filter {
            $0.value.provisionalSessionID != sessionID
        }
        if let interactionID = session.interaction?.id {
            _ = responseBroker.resolve(
                requestID: interactionID,
                response: BridgeResponse(
                    requestID: interactionID,
                    decision: .cancel,
                    message: reason + "."
                )
            )
        }
        processMonitor.stopWatching(sessionID: sessionID)
        queuedReplies.removeValue(forKey: sessionID)
        pendingCallouts.remove(sessionID: sessionID)
        pendingCalloutCount = pendingCallouts.count
        let wasCurrentCallout = calloutSessionID == sessionID
        sessionStore.dismiss(sessionID: sessionID)
        if wasCurrentCallout {
            dismissCallout()
        }
        closeTerminal(for: session)
    }

    private func watchDiscoveredProcesses(_ processes: [DiscoveredAgentSession]) {
        let liveProcessIDs = Set(processes.map(\.processID))
        for session in sessionStore.sessions {
            guard
                let processID = session.terminal.processID,
                liveProcessIDs.contains(processID)
            else {
                continue
            }
            processMonitor.watch(sessionID: session.id, processID: processID) { [weak self] in
                self?.agentProcessExited(sessionID: session.id)
            }
        }
    }

    private func closeExitedTerminalSessions(_ sessions: [AgentSession]) {
        for session in sessions {
            processMonitor.stopWatching(sessionID: session.id)
            closeTerminal(for: session)
        }
    }

    private func closeTerminal(for session: AgentSession) {
        terminalAutomation.close(session: session) { [weak self] result in
            guard case .failure(let error) = result else { return }
            if let automationError = error as? TerminalAutomationError,
               case .targetNotFound = automationError
            {
                // The user may already have closed the exact tab. The desired
                // end state has been reached, so this is not actionable.
                return
            }
            self?.showMessage(
                "The session ended, but Anton could not close its terminal tab: "
                    + error.localizedDescription
            )
        }
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
                self.setExpanded(false)
                self.capture(
                    window: self.panelController?.window,
                    to: destination.appendingPathComponent("03-compact-overflow.png")
                )
                self.showCompletionCallout(sessionID: "claude:visual-finished")
                self.showUrgentCallout(sessionID: "claude:visual-claude")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    self.capture(
                        window: self.panelController?.window,
                        to: destination.appendingPathComponent("04-callout-queued.png")
                    )

                    self.showSessionBoard()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self else { return }
                        self.capture(
                            window: self.panelController?.window,
                            to: destination.appendingPathComponent("05-session-board.png")
                        )

                        self.showSessionLauncher(mode: .new)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self else { return }
                            self.capture(
                                window: self.panelController?.window,
                                to: destination.appendingPathComponent("06-session-launcher-new.png")
                            )

                            self.seedVisualValidationResumableSessions()
                            self.sessionLauncherMode = .resume
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                guard let self else { return }
                                self.capture(
                                    window: self.panelController?.window,
                                    to: destination.appendingPathComponent(
                                        "07-session-launcher-resume.png"
                                    )
                                )

                                self.showSettings()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                                    guard let self else { return }
                                    self.capture(
                                        window: self.settingsWindowController?.window,
                                        to: destination.appendingPathComponent("08-settings.png")
                                    )
                                }
                            }
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
                    lastAssistantMessage: """
                    1. First market
                    Supporting evidence for the first market.

                    2. Second market
                    Supporting evidence for the second market.

                    3. Third market
                    """
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
        for index in 0..<3 {
            _ = sessionStore.ingest(
                BridgeRequest(
                    token: "visual-validation",
                    requestID: "visual-extra-\(index)",
                    agent: index.isMultiple(of: 2) ? .codex : .claude,
                    event: HookEventPayload(
                        name: "SessionStart",
                        sessionID: "visual-extra-\(index)",
                        cwd: "/Users/example/project-\(index)",
                        model: index.isMultiple(of: 2) ? "GPT-5" : "Claude Sonnet"
                    ),
                    terminal: TerminalContext(
                        kind: .terminal,
                        terminalSessionID: "visual-extra-terminal-\(index)",
                        tty: "/dev/ttys0\(20 + index)"
                    ),
                    sentAt: now
                ),
                now: now.addingTimeInterval(Double(-12 - index))
            )
        }
    }

    private func seedVisualValidationResumableSessions() {
        resumableSessions = [
            ResumableAgentSession(
                agent: .codex,
                sessionID: "visual-codex-resume",
                title: "Review session launcher behaviour",
                explicitName: "Session launcher",
                cwd: "/Users/example/checkout-service",
                updatedAt: Date().addingTimeInterval(-420),
                model: "gpt-5.6-terra",
                preview: "Inspect the local session catalog and verify the resume flow.",
                gitBranch: "feature/session-launcher"
            ),
            ResumableAgentSession(
                agent: .claude,
                sessionID: "visual-claude-resume",
                title: "Fix invoice extraction edge cases",
                explicitName: "Invoice extraction",
                cwd: "/Users/example/checkout-service",
                updatedAt: Date().addingTimeInterval(-3_600),
                model: "Claude Opus",
                preview: "Continue from the failing extraction fixtures."
            ),
            ResumableAgentSession(
                agent: .claude,
                sessionID: "visual-running",
                title: "Implement approval queue",
                explicitName: "Approval queue",
                cwd: "/Users/example/checkout-service",
                updatedAt: Date().addingTimeInterval(-90),
                model: "Claude Sonnet",
                isRunning: true
            )
        ]
        isLoadingSessionCatalog = false
        sessionCatalogError = nil
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
