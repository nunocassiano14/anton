import AppKit
import GilfoyleCore
import SwiftUI

struct SessionLauncherView: View {
    @ObservedObject var controller: AppController

    @State private var agent: AgentKind
    @State private var workspace: String
    @State private var sessionName = ""
    @State private var initialPrompt = ""
    @State private var terminalKind: TerminalKind
    @State private var search = ""
    @State private var allWorkspaces: Bool
    @State private var selectedSessionID: String?
    @State private var showPreviews = false

    init(controller: AppController) {
        self.controller = controller
        let initialAgent: AgentKind = controller.environment.claudePath != nil
            ? .claude
            : .codex
        _agent = State(initialValue: initialAgent)
        _workspace = State(initialValue: controller.suggestedWorkspace)
        _terminalKind = State(initialValue: controller.defaultLaunchTerminal)
        _allWorkspaces = State(initialValue: controller.sessionStore.sessions.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.065))
            if mode == .new {
                newSessionForm
            } else {
                resumeBrowser
            }
            footer
        }
        .foregroundStyle(.white)
        .onAppear {
            if mode == .resume, selectedSessionID == nil {
                selectedSessionID = filteredSessions.first?.id
            }
        }
        .onChange(of: controller.resumableSessions) { _, sessions in
            guard selectedSessionID == nil else { return }
            selectedSessionID = filteredSessions.first?.id ?? sessions.first?.id
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .resume {
                selectedSessionID = filteredSessions.first?.id
            }
        }
    }

    private var mode: AgentSessionLaunchMode {
        controller.sessionLauncherMode ?? .new
    }

    private var header: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session launcher")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text("Start fresh or continue local agent history")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.38))
                }
                Spacer()
                Button {
                    controller.closeSessionLauncher()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(NotchIconButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close launcher")
            }
            .padding(.top, topCameraInset + 10)

            AntonMark(size: 25, glows: true, compactAnimation: true)
                .padding(.top, topCameraInset + 7)
        }
        .padding(.horizontal, 20)
        .frame(height: topCameraInset + 58, alignment: .top)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            launcherModeButton("New", mode: .new, shortcut: "⌥⌘N")
            launcherModeButton("Resume", mode: .resume, shortcut: "⌥⌘R")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
    }

    private func launcherModeButton(
        _ title: String,
        mode target: AgentSessionLaunchMode,
        shortcut: String
    ) -> some View {
        Button {
            controller.sessionLauncherMode = target
        } label: {
            HStack(spacing: 8) {
                Text(title)
                Text(shortcut)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(mode == target ? Color.white.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(mode == target ? 0.92 : 0.52))
    }

    private var newSessionForm: some View {
        VStack(spacing: 18) {
            modePicker
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    formLabel("Agent")
                    agentPicker

                    formLabel("Workspace")
                    workspacePicker

                    if agent == .claude {
                        formLabel("Session name · optional")
                        launcherTextField("e.g. Baltic review", text: $sessionName)
                    }

                    formLabel("Initial prompt · optional")
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $initialPrompt)
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 108, maxHeight: 150)
                        if initialPrompt.isEmpty {
                            Text("Sent only after the agent is ready…")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.28))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(fieldSurface)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 16) {
                    formLabel("Terminal")
                    terminalPicker
                    launchExplanation
                    Spacer(minLength: 0)
                    Button {
                        startNewSession()
                    } label: {
                        Label("Start \(agent.displayName)", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black.opacity(0.88))
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(canStartNew ? 0.92 : 0.25))
                    )
                    .disabled(!canStartNew)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
                .frame(width: 245)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var agentPicker: some View {
        HStack(spacing: 8) {
            ForEach(AgentKind.allCases, id: \.self) { choice in
                Button {
                    agent = choice
                } label: {
                    HStack(spacing: 9) {
                        AgentPixelGlyph(agent: choice, state: .idle)
                            .frame(width: 22, height: 22)
                        Text(choice.displayName)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if agent == choice {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                agent == choice
                                    ? Color.white.opacity(0.11)
                                    : Color.white.opacity(0.045)
                            )
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(agent == choice ? 0.90 : 0.48))
                .disabled(executableMissing(for: choice))
            }
        }
    }

    private var workspacePicker: some View {
        HStack(spacing: 8) {
            launcherTextField("/path/to/workspace", text: $workspace)
            Button {
                controller.chooseWorkspace { path in
                    if let path { workspace = path }
                }
            } label: {
                Image(systemName: "folder")
                    .frame(width: 38, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.62))
            .background(fieldSurface)
            .help("Choose workspace")
        }
    }

    private var terminalPicker: some View {
        VStack(spacing: 7) {
            ForEach(controller.availableLaunchTerminals, id: \.rawValue) { terminal in
                Button {
                    terminalKind = terminal
                } label: {
                    HStack {
                        Image(systemName: terminal == .terminal ? "apple.terminal" : "macwindow")
                            .frame(width: 18)
                        Text(terminal.displayName)
                        Spacer()
                        if terminalKind == terminal {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 11)
                    .frame(height: 35)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                terminalKind == terminal
                                    ? Color.white.opacity(0.10)
                                    : Color.white.opacity(0.035)
                            )
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(terminalKind == terminal ? 0.82 : 0.42))
            }
        }
    }

    private var launchExplanation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Opens a new terminal tab", systemImage: "rectangle.stack.badge.play")
            Label("Waits until the agent is ready", systemImage: "checkmark.shield")
            Label("Prompt never enters process args", systemImage: "lock")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.42))
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    private var resumeBrowser: some View {
        VStack(spacing: 14) {
            modePicker
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.34))
                    TextField("Search name, workspace, model or session ID", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(fieldSurface)

                scopeButton(
                    controller.sessionStore.sessions.isEmpty
                        ? "Recent workspace"
                        : "Current workspace",
                    selected: !allWorkspaces
                ) {
                    allWorkspaces = false
                    selectedSessionID = filteredSessions.first?.id
                }
                .disabled(controller.sessionStore.sessions.isEmpty)
                scopeButton("All", selected: allWorkspaces) {
                    allWorkspaces = true
                    selectedSessionID = filteredSessions.first?.id
                }
                Button {
                    showPreviews.toggle()
                } label: {
                    Image(systemName: showPreviews ? "text.bubble.fill" : "text.bubble")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(showPreviews ? 0.78 : 0.36))
                .help(showPreviews ? "Hide private previews" : "Show local previews")
            }

            Group {
                if controller.isLoadingSessionCatalog {
                    ProgressView("Reading local session history…")
                        .controlSize(.small)
                        .foregroundStyle(.white.opacity(0.52))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredSessions.isEmpty {
                    emptyResumeState
                } else {
                    HStack(spacing: 14) {
                        sessionList
                        selectedSessionDetail
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filteredSessions) { session in
                    Button {
                        selectedSessionID = session.id
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionRow(_ session: ResumableAgentSession) -> some View {
        HStack(spacing: 11) {
            AgentPixelGlyph(
                agent: session.agent,
                state: session.isRunning ? .working : .idle,
                animationSeed: session.id
            )
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(session.displayTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if session.isRunning {
                        Text("RUNNING")
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.green.opacity(0.80))
                    }
                }
                HStack(spacing: 5) {
                    Text(session.agent == .claude ? "Claude" : "Codex")
                    Text("·")
                    Text(projectName(session.cwd))
                    Text("·")
                    Text(relativeDate(session.updatedAt))
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.34))
                if showPreviews, let preview = session.preview {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.20))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    selectedSessionID == session.id
                        ? Color.white.opacity(0.105)
                        : Color.white.opacity(0.035)
                )
        )
        .foregroundStyle(.white.opacity(selectedSessionID == session.id ? 0.88 : 0.60))
    }

    private var selectedSessionDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedSession {
                HStack {
                    AgentPixelGlyph(agent: selectedSession.agent, state: .idle)
                        .frame(width: 27, height: 27)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedSession.displayTitle)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(2)
                        Text(selectedSession.sessionID)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.26))
                            .lineLimit(1)
                    }
                }

                detailLine("Workspace", value: selectedSession.cwd.isEmpty ? "Unknown" : selectedSession.cwd)
                if let model = selectedSession.model {
                    detailLine("Model", value: model)
                }
                if let branch = selectedSession.gitBranch {
                    detailLine("Branch", value: branch)
                }
                detailLine("Updated", value: relativeDate(selectedSession.updatedAt))

                if selectedSession.cwd.isEmpty || !workspaceExists(selectedSession.cwd) {
                    Label(
                        selectedSession.cwd.isEmpty
                            ? "Original workspace is unavailable in the fallback index."
                            : "This workspace no longer exists.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange.opacity(0.78))
                }

                Spacer(minLength: 0)

                if selectedSession.isRunning {
                    launcherActionButton(
                        "Open running session",
                        icon: "rectangle.expand.vertical",
                        enabled: true
                    ) {
                        resumeSelected(mode: .resume)
                    }
                } else {
                    terminalPicker
                    launcherActionButton("Resume session", icon: "arrow.counterclockwise") {
                        resumeSelected(mode: .resume)
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    Button {
                        resumeSelected(mode: .fork)
                    } label: {
                        Label("Fork as new session", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.56))
                    .background(fieldSurface)
                    .disabled(!canResumeSelected)
                }
            } else {
                Text("Select a saved session")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.34))
                Spacer()
            }
        }
        .padding(15)
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var emptyResumeState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 23))
                .foregroundStyle(.white.opacity(0.34))
            Text(controller.sessionCatalogError ?? "No matching saved sessions")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
            Button("Show all workspaces") {
                allWorkspaces = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.70))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
            Text("Local only · /rename name, otherwise Git branch")
            Spacer()
            Text("⌘↩ start")
            Text("·")
            Text("esc close")
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.28))
        .padding(.horizontal, 22)
        .frame(height: 36)
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.055))
        }
    }

    private var filteredSessions: [ResumableAgentSession] {
        ResumableSessionParser.filtered(
            controller.resumableSessions,
            query: search,
            workspace: controller.sessionStore.sessions.first?.cwd,
            allWorkspaces: allWorkspaces
        )
    }

    private var selectedSession: ResumableAgentSession? {
        controller.resumableSessions.first { $0.id == selectedSessionID }
    }

    private var canStartNew: Bool {
        !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && workspaceExists(workspace)
            && !executableMissing(for: agent)
            && controller.availableLaunchTerminals.contains(terminalKind)
    }

    private var canResumeSelected: Bool {
        guard let selectedSession else { return false }
        return !selectedSession.cwd.isEmpty
            && workspaceExists(selectedSession.cwd)
            && controller.availableLaunchTerminals.contains(terminalKind)
    }

    private func startNewSession() {
        controller.startAgentSession(
            agent: agent,
            mode: .new,
            workspace: workspace,
            name: sessionName,
            initialPrompt: initialPrompt,
            terminalKind: terminalKind
        )
    }

    private func resumeSelected(mode: AgentSessionLaunchMode) {
        guard let selectedSession else { return }
        controller.startAgentSession(
            agent: selectedSession.agent,
            mode: mode,
            workspace: selectedSession.cwd,
            name: "",
            initialPrompt: "",
            terminalKind: terminalKind,
            candidate: selectedSession
        )
    }

    private func launcherActionButton(
        _ title: String,
        icon: String,
        enabled: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isEnabled = enabled ?? canResumeSelected
        return Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black.opacity(0.86))
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(isEnabled ? 0.90 : 0.25))
        )
        .disabled(!isEnabled)
    }

    private func scopeButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.11) : Color.white.opacity(0.035))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(selected ? 0.76 : 0.36))
    }

    private func launcherTextField(
        _ placeholder: String,
        text: Binding<String>
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(fieldSurface)
    }

    private var fieldSurface: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
            }
    }

    private func formLabel(_ value: String) -> some View {
        Text(value.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.30))
    }

    private func detailLine(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.25))
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func executableMissing(for choice: AgentKind) -> Bool {
        choice == .claude
            ? controller.environment.claudePath == nil
            : controller.environment.codexPath == nil
    }

    private func workspaceExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func projectName(_ path: String) -> String {
        guard !path.isEmpty else { return "Unknown workspace" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var topCameraInset: CGFloat {
        let mainDisplayID = CGMainDisplayID()
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == mainDisplayID
        } ?? NSScreen.main
        return screen?.safeAreaInsets.top ?? 0
    }
}
