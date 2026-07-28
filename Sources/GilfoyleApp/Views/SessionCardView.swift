import GilfoyleCore
import SwiftUI

struct SessionCardView: View {
    @ObservedObject var controller: AppController
    let session: AgentSession
    let expandedByDefault: Bool

    @State private var reply = ""
    @State private var revealsDetail: Bool
    @State private var attachments: [URL] = []
    @State private var isSending = false
    @State private var isConfirmingEndSession = false

    init(
        controller: AppController,
        session: AgentSession,
        expandedByDefault: Bool = false,
        confirmEndByDefault: Bool = false
    ) {
        self.controller = controller
        self.session = session
        self.expandedByDefault = expandedByDefault
        self._revealsDetail = State(
            initialValue: SessionDisclosurePolicy.initial(
                expandedByDefault: expandedByDefault,
                state: session.state,
                forceOpen: confirmEndByDefault
            )
        )
        self._isConfirmingEndSession = State(initialValue: confirmEndByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if revealsDetail {
                detail
                    .padding(.leading, 45)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 15)
        .background(Color.white.opacity(session.state.needsUser ? 0.032 : 0.001))
        .animation(.easeOut(duration: 0.18), value: revealsDetail)
        .onChange(of: expandedByDefault) { _, value in
            if value { revealsDetail = true }
        }
        .onChange(of: session.state) { _, state in
            revealsDetail = SessionDisclosurePolicy.afterStateChange(
                current: revealsDetail,
                state: state
            )
            if state == .disconnected {
                isConfirmingEndSession = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(session.agent.displayName), \(session.projectName), \(session.state.displayName)"
        )
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Button {
                revealsDetail = SessionDisclosurePolicy.toggled(revealsDetail)
            } label: {
                HStack(spacing: 13) {
                    AgentPixelGlyph(agent: session.agent, state: session.state, animationSeed: session.id)
                        .frame(width: 31, height: 31)
                        .opacity(session.state == .working ? 1 : 0.36)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(summaryTitle)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)

                        HStack(spacing: 7) {
                            Circle()
                                .fill(stateColor.opacity(session.state == .working ? 1 : 0.36))
                                .frame(width: 5, height: 5)
                                .shadow(
                                    color: stateColor.opacity(session.state == .working ? 0.75 : 0),
                                    radius: 4
                                )
                            Text(session.currentActivity ?? session.state.displayName)
                                .lineLimit(1)
                            if let action = session.lastAction,
                               action != session.currentActivity {
                                Text("·")
                                Text(action)
                                    .fontDesign(.monospaced)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.48))
                    }

                    Spacer(minLength: 10)

                    Image(systemName: revealsDetail ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.26))
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("Open terminal") {
                    controller.focus(sessionID: session.id)
                }
                if canEndSession {
                    Button("End session…", role: .destructive) {
                        requestEndSessionConfirmation()
                    }
                }
                Divider()
                Button("Dismiss") {
                    controller.dismiss(sessionID: session.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Session actions")
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailContent

            if isConfirmingEndSession {
                EndSessionConfirmationView(
                    agentName: session.agent.displayName,
                    isEnding: controller.endingSessionIDs.contains(session.id),
                    cancel: { isConfirmingEndSession = false },
                    confirm: {
                        isConfirmingEndSession = false
                        controller.endSession(sessionID: session.id)
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: isConfirmingEndSession)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let pending = session.interaction, pending.kind == .approval {
            ApprovalInteractionView(
                interaction: pending,
                allow: { controller.allow(interactionID: pending.id, sessionID: session.id) },
                deny: { controller.deny(interactionID: pending.id, sessionID: session.id) }
            )
        } else if let pending = session.interaction,
                  pending.kind == .question || pending.kind == .elicitation {
            QuestionInteractionView(
                interaction: pending,
                submit: {
                    controller.answer(
                        interactionID: pending.id,
                        sessionID: session.id,
                        answers: $0
                    )
                },
                cancel: {
                    controller.cancel(interactionID: pending.id, sessionID: session.id)
                }
            )
        } else if session.state == .working {
            VStack(alignment: .leading, spacing: 9) {
                replyEditor(
                    placeholder: "Queue a message for \(session.agent.displayName)…",
                    submit: queueCurrentReply
                )

                HStack {
                    Text("Sent automatically when this turn finishes")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.28))
                    Spacer()
                    copyResponseButton
                }
            }
        } else if session.state == .finished || session.state == .idle || session.state == .error {
            VStack(alignment: .leading, spacing: 9) {
                if let preview = session.lastResponsePreview {
                    MarkdownResponseView(markdown: preview)
                }
                replyEditor(
                    placeholder: "Reply to \(session.agent.displayName)…",
                    autoFocus: expandedByDefault,
                    submit: sendCurrentReply
                )

                HStack {
                    Text("Enter to send · Shift+Enter for a new line")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.28))
                    Spacer()
                    copyResponseButton
                }
            }
        } else {
            HStack {
                Text("\(session.agent.displayName) is \(session.state.displayName.lowercased()) in \(session.terminal.kind.displayName).")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                copyResponseButton
            }
        }
    }

    private var canEndSession: Bool {
        guard let processID = session.terminal.processID else { return false }
        return processID > 1
            && session.state != .disconnected
            && !controller.endingSessionIDs.contains(session.id)
    }

    private func requestEndSessionConfirmation() {
        revealsDetail = true
        isConfirmingEndSession = true
    }

    private var summaryTitle: String {
        let lead = session.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = lead.flatMap { $0.isEmpty ? nil : $0 } ?? session.agent.displayName
        if let name = session.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return "\(model) · \(name)"
        }
        if let title = conciseTerminalTitle(session.terminal.tabTitle) {
            return "\(model) · \(title)"
        }
        let terminal = session.terminal.tty?.split(separator: "/").last.map(String.init)
        return "\(model) · \(terminal ?? session.projectName)"
    }

    /// Terminal window titles include the working directory, shell and size.
    /// Keep only the part that differentiates one live agent session from
    /// another, such as `node`, `ps`, or `Chat with Claude`.
    private func conciseTerminalTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let parts = title
            .split(separator: "—")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        if let conversation = parts.first(where: {
            $0.localizedCaseInsensitiveContains("chat")
                || $0.localizedCaseInsensitiveContains("conversation")
        }) {
            return conversation.trimmingCharacters(in: CharacterSet(charactersIn: "✳⠁⠂⠃⠄⠅⠆⠇⠈⠉⠊⠋⠌⠍⠎⠏ "))
        }

        if let agentPart = parts.first(where: {
            $0.localizedCaseInsensitiveContains("codex")
                || $0.localizedCaseInsensitiveContains("claude")
        }) {
            let pieces = agentPart
                .split(separator: "▸", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if pieces.count == 2, !pieces[1].isEmpty {
                return pieces[1]
            }
        }
        return nil
    }

    private var replyComposerBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.075))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.19), lineWidth: 0.9)
            }
    }

    private func replyEditor(
        placeholder: String,
        autoFocus: Bool = false,
        submit: @escaping () -> Void
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ReplyTextView(
                text: $reply,
                placeholder: placeholder,
                autoFocus: autoFocus,
                onBeginEditing: { controller.beginExplicitReply() },
                onPasteImage: { image in
                    if let url = ScreenshotAttachmentStore.save(image) {
                        attachments.append(url)
                    }
                },
                onSubmit: { _ in submit() },
                onCancel: { controller.collapsePanel() }
            )
            Button {
                controller.beginExplicitReply()
                // File import is intentional user input. Promote the
                // otherwise passive notch panel before presenting the system
                // picker, so Attach File works from the expanded hub too.
                DispatchQueue.main.async {
                    controller.chooseAttachments { urls in
                        attachments.append(contentsOf: urls)
                    }
                }
            } label: {
                Image(systemName: attachments.isEmpty ? "paperclip" : "paperclip.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(attachments.isEmpty ? .white.opacity(0.42) : .white.opacity(0.88))
            .padding(5)
            .help(attachments.isEmpty ? "Attach files" : "Files attached")
            if !attachments.isEmpty {
                HStack(spacing: 5) {
                    ForEach(attachments.indices, id: \.self) { index in
                        Button {
                            attachments.remove(at: index)
                        } label: {
                            Label(attachmentLabel(for: attachments[index], index: index), systemImage: attachmentIcon(for: attachments[index]))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.11)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.72))
                        .help("Remove \(attachmentLabel(for: attachments[index], index: index))")
                    }
                }
                .padding(6)
            }
        }
        .frame(height: 58)
        .background(replyComposerBackground)
    }

    private func replyPayload(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return trimmed }
        let lead = trimmed.isEmpty ? "Please inspect the attached file." : trimmed
        let paths = attachments.enumerated()
            .map { "\(attachmentLabel(for: $0.element, index: $0.offset)) attached locally: \($0.element.path)" }
            .joined(separator: "\n")
        return "\(lead)\n\n\(paths)"
    }

    private func queueCurrentReply() {
        let payload = replyPayload(reply)
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        controller.queueReply(payload, to: session.id)
        clearComposer()
    }

    private func sendCurrentReply() {
        guard !isSending else { return }
        let payload = replyPayload(reply)
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        controller.sendReply(payload, to: session.id) { success in
            isSending = false
            if success {
                clearComposer()
            }
        }
    }

    private func clearComposer() {
        reply = ""
        attachments = []
    }

    private func attachmentLabel(for url: URL, index: Int) -> String {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name.hasPrefix("screenshot-") || name.hasPrefix("image-") {
            return "Screenshot \(index + 1)"
        }
        return url.lastPathComponent
    }

    private func attachmentIcon(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.hasPrefix("screenshot-") || name.hasPrefix("image-") ? "photo" : "doc"
    }

    @ViewBuilder
    private var copyResponseButton: some View {
        if session.lastResponsePreview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            Button("Copy response") {
                controller.copyResponse(sessionID: session.id)
            }
            .buttonStyle(QuietButtonStyle())
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .working: return Color(red: 0.44, green: 0.74, blue: 1)
        case .needsApproval: return Color.orange
        case .hasQuestion: return Color(red: 0.82, green: 0.61, blue: 1)
        case .finished: return Color(red: 0.47, green: 0.88, blue: 0.68)
        case .idle: return Color.white.opacity(0.5)
        case .error: return Color(red: 1, green: 0.38, blue: 0.4)
        case .disconnected: return Color.white.opacity(0.28)
        }
    }

}

private struct EndSessionConfirmationView: View {
    let agentName: String
    let isEnding: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color(red: 1, green: 0.38, blue: 0.4))

            VStack(alignment: .leading, spacing: 3) {
                Text("End this \(agentName) session?")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Current work stops immediately. The terminal tab stays open.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer(minLength: 10)

            Button("Cancel", action: cancel)
                .buttonStyle(QuietButtonStyle())
                .disabled(isEnding)
            Button(isEnding ? "Ending…" : "End session", action: confirm)
                .buttonStyle(DangerButtonStyle())
                .disabled(isEnding)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(red: 0.24, green: 0.055, blue: 0.065).opacity(0.74))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            Color(red: 1, green: 0.38, blue: 0.4).opacity(0.25),
                            lineWidth: 0.8
                        )
                }
        )
    }
}

private struct ApprovalInteractionView: View {
    let interaction: PendingInteraction
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let detail = interaction.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
            }
            HStack(spacing: 8) {
                Button("Deny", action: deny)
                    .buttonStyle(DangerButtonStyle())
                Button("Allow", action: allow)
                    .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct QuestionInteractionView: View {
    let interaction: PendingInteraction
    let submit: ([String: String]) -> Void
    let cancel: () -> Void

    @State private var answers: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(interaction.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header {
                        Text(header.uppercased())
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    Text(question.prompt)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))

                    if !question.options.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(question.options) { option in
                                Button {
                                    select(option: option, for: question)
                                } label: {
                                    HStack(spacing: 5) {
                                        if isSelected(option: option, for: question) {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(option.label)
                                    }
                                }
                                .buttonStyle(
                                    ChoiceButtonStyle(
                                        selected: isSelected(option: option, for: question)
                                    )
                                )
                                .help(option.detail ?? option.label)
                            }
                        }
                    }

                    TextField(
                        "",
                        text: Binding(
                            get: { answers[question.id] ?? "" },
                            set: {
                                answers[question.id] = $0
                                selections[question.id] = []
                            }
                        ),
                        prompt: Text("Or type an answer…")
                            .foregroundStyle(.white.opacity(0.28))
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    }
                    .onSubmit {
                        if !answers.isEmpty { submit(answers) }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Cancel", action: cancel)
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Send answer") { submit(answers) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(answers.values.allSatisfy {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
            }
        }
    }

    private func isSelected(
        option: AgentQuestionOption,
        for question: AgentQuestion
    ) -> Bool {
        selections[question.id]?.contains(option.label) == true
    }

    private func select(
        option: AgentQuestionOption,
        for question: AgentQuestion
    ) {
        if question.allowsMultiple {
            var selected = selections[question.id] ?? []
            if selected.contains(option.label) {
                selected.remove(option.label)
            } else {
                selected.insert(option.label)
            }
            selections[question.id] = selected
            answers[question.id] = question.options
                .map(\.label)
                .filter(selected.contains)
                .joined(separator: ", ")
        } else {
            selections[question.id] = [option.label]
            answers[question.id] = option.label
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black.opacity(isEnabled ? 0.86 : 0.42))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(
                Capsule().fill(
                    Color(red: 0.57, green: 0.88, blue: 0.73)
                        .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.28)
                )
            )
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.5))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(
                Capsule().fill(Color(red: 1, green: 0.3, blue: 0.34).opacity(configuration.isPressed ? 0.2 : 0.1))
            )
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.9 : 0.5))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0.055)))
    }
}

private struct ChoiceButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.white.opacity(0.66))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule().fill(
                    selected
                        ? Color(red: 0.72, green: 0.59, blue: 1)
                        : Color.white.opacity(configuration.isPressed ? 0.12 : 0.06)
                )
            )
    }
}
