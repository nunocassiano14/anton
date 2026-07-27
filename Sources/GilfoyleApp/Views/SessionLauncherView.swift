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
    @State private var showAdvanced = false
    @State private var branchSnapshot = WorkspaceGitBranches.empty(workspace: "")
    @State private var selectedBranch: String?
    @State private var pendingBranchSelection: String?
    @State private var branchLookupGeneration = 0
    @State private var isLoadingBranches = false
    @FocusState private var promptFocused: Bool

    init(controller: AppController) {
        self.controller = controller
        let initialWorkspace = controller.suggestedWorkspace
        _agent = State(initialValue: controller.preferredLaunchAgent)
        _workspace = State(initialValue: initialWorkspace)
        _branchSnapshot = State(
            initialValue: WorkspaceGitBranches.empty(workspace: initialWorkspace)
        )
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
            } else if mode == .new {
                refreshBranchContext()
                DispatchQueue.main.async {
                    promptFocused = true
                }
            }
        }
        .onChange(of: controller.resumableSessions) { _, sessions in
            guard selectedSessionID == nil else { return }
            selectedSessionID = filteredSessions.first?.id ?? sessions.first?.id
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .resume {
                selectedSessionID = filteredSessions.first?.id
            } else {
                refreshBranchContext()
            }
        }
        .onChange(of: workspace) { _, _ in
            scheduleBranchRefresh()
        }
    }

    private var mode: AgentSessionLaunchMode {
        controller.sessionLauncherMode ?? .new
    }

    private var header: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .new ? "New session" : "Resume session")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text(
                        mode == .new
                            ? "Give an agent a task without leaving Anton"
                            : "Continue a named local conversation"
                    )
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

    private var newSessionForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            launchContextBar

            VStack(alignment: .leading, spacing: 9) {
                Text("What should \(agent.displayName) work on?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $initialPrompt)
                        .focused($promptFocused)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                    if initialPrompt.isEmpty {
                        Text("Describe the task. Anton sends it only after the agent is connected…")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.white.opacity(0.25))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 17)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 190, maxHeight: 250)
                .background(composerSurface)
            }

            HStack(spacing: 10) {
                branchPicker
                launcherTextField(
                    "Session name · optional",
                    text: $sessionName
                )
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    Label(
                        showAdvanced ? "Hide options" : "Options",
                        systemImage: "slider.horizontal.3"
                    )
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(height: 36)
                    .padding(.horizontal, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(showAdvanced ? 0.76 : 0.46))
                .background(fieldSurface)
            }

            if showAdvanced {
                advancedLaunchOptions
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(launchSummary)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Opening → connecting → sending prompt")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.25))
                }
                Spacer()
                Button {
                    startNewSession()
                } label: {
                    HStack(spacing: 8) {
                        Text(
                            initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Open \(agent.displayName)"
                                : "Start \(agent.displayName)"
                        )
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 40)
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
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var launchContextBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(AgentKind.allCases, id: \.self) { choice in
                    Button {
                        agent = choice
                    } label: {
                        HStack(spacing: 7) {
                            AgentPixelGlyph(agent: choice, state: .idle)
                                .frame(width: 18, height: 18)
                            Text(choice == .claude ? "Claude" : "Codex")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(
                                    agent == choice
                                        ? Color.white.opacity(0.12)
                                        : Color.clear
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(agent == choice ? 0.88 : 0.36))
                    .disabled(executableMissing(for: choice))
                }
            }
            .padding(3)
            .background(fieldSurface)

            workspacePicker
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

    private var branchPicker: some View {
        Menu {
            if !branchSnapshot.localBranches.isEmpty {
                Section("Current workspace") {
                    ForEach(branchSnapshot.localBranches, id: \.self) { branch in
                        Button {
                            chooseBranch(branch, workspace: branchSnapshot.workspace)
                        } label: {
                            HStack {
                                Text(branch)
                                if branch == branchSnapshot.currentBranch {
                                    Text("Current")
                                }
                                if branch == selectedBranch {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if !recentBranchReferences.isEmpty {
                Section("From Claude & Codex") {
                    ForEach(recentBranchReferences) { reference in
                        Button {
                            chooseBranch(
                                reference.name,
                                workspace: reference.workspace
                            )
                        } label: {
                            Text(
                                "\(reference.name) — "
                                    + "\(workspaceLabel(reference.workspace)) · "
                                    + (reference.agent == .claude ? "Claude" : "Codex")
                            )
                        }
                    }
                }
            }

            if branchSnapshot.localBranches.isEmpty,
               recentBranchReferences.isEmpty
            {
                Text("No local or agent branches found")
            }
        } label: {
            HStack(spacing: 7) {
                if isLoadingBranches {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .medium))
                }
                Text(branchPickerTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(selectedBranch == nil ? 0.38 : 0.72))
            .padding(.horizontal, 11)
            .frame(width: 255, height: 36)
            .background(fieldSurface)
        }
        .menuStyle(.borderlessButton)
        .disabled(
            isLoadingBranches
                || (
                    branchSnapshot.localBranches.isEmpty
                        && recentBranchReferences.isEmpty
                )
        )
        .help(
            selectedBranch == nil
                ? "Choose a branch from this repository or recent agent history"
                : "Anton starts the agent on \(selectedBranch ?? "")"
        )
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

    private var advancedLaunchOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            formLabel("Terminal")
            HStack(spacing: 8) {
                ForEach(controller.availableLaunchTerminals, id: \.rawValue) { terminal in
                    Button {
                        terminalKind = terminal
                    } label: {
                        HStack(spacing: 7) {
                            Image(
                                systemName: terminal == .terminal
                                    ? "apple.terminal"
                                    : "macwindow"
                            )
                            Text(terminal.displayName)
                            if terminalKind == terminal {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
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
                    .foregroundStyle(
                        .white.opacity(terminalKind == terminal ? 0.78 : 0.36)
                    )
                }
                Spacer()
                Label("Remembered for next time", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    private var resumeBrowser: some View {
        VStack(spacing: 14) {
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
            Text("Local only · custom name → selected Git branch → workspace")
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

    private var recentBranchReferences: [AgentBranchReference] {
        let localKeys = Set(
            branchSnapshot.localBranches.map {
                "\(branchSnapshot.workspace)\u{0}\($0)"
            }
        )
        return Array(
            controller.recentAgentBranches
                .filter { !localKeys.contains($0.id) }
                .prefix(12)
        )
    }

    private var branchPickerTitle: String {
        if isLoadingBranches {
            return "Reading branches…"
        }
        if let selectedBranch {
            return selectedBranch
        }
        if !recentBranchReferences.isEmpty {
            return "Choose branch"
        }
        return "No Git branch"
    }

    private var launchSummary: String {
        guard let selectedBranch else {
            return "Anton opens \(terminalKind.displayName) in the background"
        }
        if branchSnapshot.currentBranch == selectedBranch {
            return "Use \(selectedBranch), then open \(terminalKind.displayName)"
        }
        return "Switch to \(selectedBranch), then open \(terminalKind.displayName)"
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
            gitBranch: selectedBranch,
            initialPrompt: initialPrompt,
            terminalKind: terminalKind
        )
    }

    private func chooseBranch(_ branch: String, workspace branchWorkspace: String) {
        selectedBranch = branch
        let target = (branchWorkspace as NSString).standardizingPath
        let current = (workspace as NSString).standardizingPath
        guard target != current else { return }
        pendingBranchSelection = branch
        workspace = target
    }

    private func scheduleBranchRefresh() {
        branchLookupGeneration += 1
        let generation = branchLookupGeneration
        isLoadingBranches = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard generation == branchLookupGeneration else { return }
            loadBranchContext(generation: generation)
        }
    }

    private func refreshBranchContext() {
        branchLookupGeneration += 1
        isLoadingBranches = true
        loadBranchContext(generation: branchLookupGeneration)
    }

    private func loadBranchContext(generation: Int) {
        let requestedWorkspace = workspace
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredBranch = pendingBranchSelection
        controller.loadGitBranches(for: requestedWorkspace) { snapshot in
            guard
                generation == branchLookupGeneration,
                requestedWorkspace
                    == workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return
            }
            branchSnapshot = snapshot
            isLoadingBranches = false
            pendingBranchSelection = nil
            if let preferredBranch {
                if snapshot.localBranches.contains(preferredBranch) {
                    selectedBranch = preferredBranch
                } else {
                    selectedBranch = snapshot.currentBranch
                    controller.showMessage(
                        "\(preferredBranch) no longer exists locally in "
                            + workspaceLabel(requestedWorkspace)
                            + "."
                    )
                }
            } else {
                selectedBranch = snapshot.currentBranch
            }
        }
    }

    private func workspaceLabel(_ path: String) -> String {
        let label = URL(fileURLWithPath: path).lastPathComponent
        return label.isEmpty ? path : label
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

    private var composerSurface: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.13), lineWidth: 0.8)
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
