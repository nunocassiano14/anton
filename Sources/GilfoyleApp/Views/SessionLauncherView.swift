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
    @State private var selectedSessionID: String?
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
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.065))
            VStack(spacing: 16) {
                primaryChoices
                if mode == .new {
                    newSessionFlow
                } else {
                    existingSessionFlow
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .foregroundStyle(.white)
        .onAppear {
            selectFirstExistingSessionIfNeeded()
            if mode == .new {
                refreshBranchContext()
                focusPrompt()
            }
        }
        .onChange(of: controller.resumableSessions) { _, _ in
            selectFirstExistingSessionIfNeeded(force: true)
        }
        .onChange(of: agent) { _, _ in
            selectFirstExistingSessionIfNeeded(force: true)
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .new {
                refreshBranchContext()
                focusPrompt()
            } else {
                selectedSessionID = existingSessions.first?.id
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
                    Text("Start session")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text("Choose an agent, then start fresh or continue")
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

    private var primaryChoices: some View {
        HStack(spacing: 12) {
            selectorGroup {
                agentSelector(.claude, title: "Claude Code")
                agentSelector(.codex, title: "Codex")
            }

            selectorGroup {
                modeSelector(.new, title: "New", icon: "plus")
                modeSelector(
                    .resume,
                    title: "Existing",
                    icon: "clock.arrow.circlepath"
                )
            }

            Spacer(minLength: 0)
        }
    }

    private func selectorGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 3) {
            content()
        }
        .padding(3)
        .background(fieldSurface)
    }

    private func agentSelector(_ choice: AgentKind, title: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                agent = choice
            }
        } label: {
            HStack(spacing: 7) {
                AgentPixelGlyph(agent: choice, state: .idle)
                    .frame(width: 18, height: 18)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(selectorHighlight(selected: agent == choice))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(agent == choice ? 0.90 : 0.38))
        .disabled(executableMissing(for: choice))
    }

    private func modeSelector(
        _ choice: AgentSessionLaunchMode,
        title: String,
        icon: String
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                controller.sessionLauncherMode = choice
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(selectorHighlight(selected: mode == choice))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(mode == choice ? 0.90 : 0.38))
    }

    private func selectorHighlight(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.white.opacity(0.12) : Color.clear)
    }

    private var newSessionFlow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("What should \(agent.displayName) work on?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
                Spacer()
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
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(showAdvanced ? 0.72 : 0.38))
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $initialPrompt)
                    .focused($promptFocused)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                if initialPrompt.isEmpty {
                    Text(
                        "Describe the task. Anton sends it after "
                            + "\(agent.displayName) is connected…"
                    )
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 17)
                    .allowsHitTesting(false)
                }
            }
            .frame(minHeight: showAdvanced ? 165 : 235)
            .background(composerSurface)

            if showAdvanced {
                newSessionOptions
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(launchSummary)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                            initialPrompt
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
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
                .background(primaryButtonSurface(enabled: canStartNew))
                .disabled(!canStartNew)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var newSessionOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                workspacePicker
                branchPicker
            }
            HStack(spacing: 10) {
                launcherTextField("Session name · optional", text: $sessionName)
                terminalMenu
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    private var existingSessionFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Existing \(agent.displayName) sessions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.80))
                    Text("Names come from /rename, --name or the Git branch")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.30))
                }
                Spacer()
                if !controller.isLoadingSessionCatalog {
                    Text("\(existingSessions.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }

            Group {
                if controller.isLoadingSessionCatalog {
                    loadingSessions
                } else if existingSessions.isEmpty {
                    emptyExistingSessions
                } else {
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(existingSessions) { session in
                                Button {
                                    selectedSessionID = session.id
                                } label: {
                                    existingSessionRow(session)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if !session.isRunning {
                                        Button("Fork as new session") {
                                            launchExisting(session, mode: .fork)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            existingSessionAction
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func existingSessionRow(
        _ session: ResumableAgentSession
    ) -> some View {
        let selected = selectedSessionID == session.id
        let available = !session.cwd.isEmpty && workspaceExists(session.cwd)
        return HStack(spacing: 12) {
            AgentPixelGlyph(
                agent: session.agent,
                state: session.isRunning ? .working : .idle,
                animationSeed: session.id
            )
            .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(session.displayTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if session.isRunning {
                        Text("RUNNING")
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.green.opacity(0.80))
                    } else if !available {
                        Text("MISSING WORKSPACE")
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.orange.opacity(0.72))
                    }
                }
                HStack(spacing: 5) {
                    Text(projectName(session.cwd))
                    Text("·")
                    Text(relativeDate(session.updatedAt))
                    if let branch = session.gitBranch,
                       branch != session.displayTitle
                    {
                        Text("·")
                        Text(branch)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.32))
            }

            Spacer(minLength: 8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 0.72 : 0.16))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    selected
                        ? Color.white.opacity(0.105)
                        : Color.white.opacity(0.035)
                )
        )
        .foregroundStyle(.white.opacity(selected ? 0.88 : available ? 0.62 : 0.34))
    }

    private var existingSessionAction: some View {
        HStack(spacing: 12) {
            if let selectedSession {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedSession.displayTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                        .lineLimit(1)
                    Text(selectedSession.cwd)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.25))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Select a session to continue")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.30))
            }
            Spacer()
            Button {
                resumeSelected(mode: .resume)
            } label: {
                HStack(spacing: 8) {
                    Text(selectedSession?.isRunning == true ? "Open session" : "Resume")
                    Image(
                        systemName: selectedSession?.isRunning == true
                            ? "rectangle.expand.vertical"
                            : "arrow.counterclockwise"
                    )
                }
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 18)
                .frame(height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black.opacity(0.88))
            .background(primaryButtonSurface(enabled: canResumeSelected))
            .disabled(!canResumeSelected)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private var loadingSessions: some View {
        VStack(spacing: 9) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(index == 0 ? 0.06 : 0.035))
                    .frame(height: 58)
            }
        }
        .overlay {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var emptyExistingSessions: some View {
        VStack(spacing: 10) {
            AgentPixelGlyph(agent: agent, state: .idle)
                .frame(width: 31, height: 31)
                .opacity(0.50)
            Text("No saved \(agent.displayName) sessions")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
            Text("Start a new one or rename a session in the CLI.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.28))
            Button("Start new") {
                controller.sessionLauncherMode = .new
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.70))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(width: 245, height: 36)
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

    private var terminalMenu: some View {
        Menu {
            ForEach(controller.availableLaunchTerminals, id: \.rawValue) { terminal in
                Button {
                    terminalKind = terminal
                } label: {
                    HStack {
                        Text(terminal.displayName)
                        if terminalKind == terminal {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(
                    systemName: terminalKind == .terminal
                        ? "apple.terminal"
                        : "macwindow"
                )
                Text(terminalKind.displayName)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.horizontal, 11)
            .frame(width: 155, height: 36)
            .background(fieldSurface)
        }
        .menuStyle(.borderlessButton)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
            Text(
                mode == .new
                    ? "Local only · advanced setup stays under Options"
                    : "Local only · session names never use prompt text"
            )
            Spacer()
            Text("⌘↩ \(mode == .new ? "start" : "resume")")
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

    private var existingSessions: [ResumableAgentSession] {
        controller.resumableSessions
            .filter { $0.agent == agent }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var selectedSession: ResumableAgentSession? {
        existingSessions.first { $0.id == selectedSessionID }
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
        return selectedSession.isRunning
            || (
                !selectedSession.cwd.isEmpty
                    && workspaceExists(selectedSession.cwd)
                    && controller.availableLaunchTerminals.contains(terminalKind)
            )
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

    private func resumeSelected(mode: AgentSessionLaunchMode) {
        guard let selectedSession else { return }
        launchExisting(selectedSession, mode: mode)
    }

    private func launchExisting(
        _ session: ResumableAgentSession,
        mode: AgentSessionLaunchMode
    ) {
        controller.startAgentSession(
            agent: session.agent,
            mode: mode,
            workspace: session.cwd,
            name: "",
            initialPrompt: "",
            terminalKind: terminalKind,
            candidate: session
        )
    }

    private func selectFirstExistingSessionIfNeeded(force: Bool = false) {
        guard mode != .new else { return }
        if force || selectedSession == nil {
            selectedSessionID = existingSessions.first?.id
        }
    }

    private func focusPrompt() {
        DispatchQueue.main.async {
            promptFocused = true
        }
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

    private func primaryButtonSurface(enabled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(enabled ? 0.92 : 0.25))
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

    private func projectName(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "Unknown workspace" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func workspaceLabel(_ path: String) -> String {
        let label = URL(fileURLWithPath: path).lastPathComponent
        return label.isEmpty ? path : label
    }

    private func relativeDate(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return "now"
        case ..<3_600:
            return "\(Int(seconds / 60)) min ago"
        case ..<86_400:
            return "\(Int(seconds / 3_600)) hr ago"
        case ..<604_800:
            return "\(Int(seconds / 86_400)) d ago"
        default:
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private var topCameraInset: CGFloat {
        let mainDisplayID = CGMainDisplayID()
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == mainDisplayID
        } ?? NSScreen.main
        return max(12, screen?.safeAreaInsets.top ?? 0)
    }
}
