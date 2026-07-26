import AppKit
import GilfoyleCore
import SwiftUI

struct NotchRootView: View {
    @ObservedObject private var controller: AppController
    @ObservedObject private var store: SessionStore
    @State private var calloutReply = ""
    @State private var calloutAttachments: [URL] = []
    @State private var isSendingCalloutReply = false

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sessionStore
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchSurface(expanded: controller.isExpanded)
                .fill(Color.black.opacity(0.995))
                .overlay {
                    NotchSurface(expanded: controller.isExpanded)
                        .stroke(Color.white.opacity(controller.isExpanded ? 0.075 : 0.045), lineWidth: 0.7)
                }

            if let calloutSession {
                completionCallout(session: calloutSession)
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            } else if controller.isExpanded {
                sessionBoard
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            } else {
                compactContent
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: controller.isExpanded)
        .animation(.easeOut(duration: 0.18), value: controller.calloutSessionID)
        .onChange(of: controller.calloutSessionID) { _, _ in
            // Drafts are scoped to the callout session. Never carry text or
            // local file paths into a different agent conversation.
            calloutReply = ""
            calloutAttachments = []
            isSendingCalloutReply = false
            controller.setCalloutHasAttachments(false)
        }
        .onChange(of: calloutAttachments.count) { _, count in
            controller.setCalloutHasAttachments(count > 0)
        }
        .overlay {
            if !controller.isExpanded {
                Button {
                    controller.showSessionBoard()
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Anton live session board")
                .accessibilityHint("Opens the live session board")
            }
        }
        // NSHostingController otherwise asks this view for its compact intrinsic
        // height after a transition. The board must own the full NSPanel frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Anton agent monitor")
    }

    private var calloutSession: AgentSession? {
        guard
            controller.isExpanded,
            let sessionID = controller.calloutSessionID
        else {
            return nil
        }
        return store.session(id: sessionID)
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            AntonMark(size: 23, glows: true, compactAnimation: true)

            Spacer()

            HStack(spacing: 6) {
                ForEach(compactSessions, id: \.id) { session in
                    AgentPixelGlyph(
                        agent: session.agent,
                        state: session.state,
                        animationSeed: session.id
                    )
                    .frame(width: 21, height: 21)
                    // Working is the only high-energy signal in compact
                    // mode. Ready, idle and attention states remain visible
                    // by agent colour, but recede until they need opening.
                    .opacity(session.state == .working ? 1 : 0.34)
                    .accessibilityLabel(compactAccessibilityLabel(for: session))
                }
                if store.sessions.count > compactSessions.count {
                    Text("+\(store.sessions.count - compactSessions.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func completionCallout(session: AgentSession) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
            Button {
                controller.showSessionBoard()
            } label: {
                AntonMark(size: 28, glows: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, topCameraInset + 3)
                    .frame(height: topCameraInset + 40, alignment: .top)
            }
            .buttonStyle(.plain)
            .help("Show every session")

            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    AgentPixelGlyph(agent: session.agent, state: session.state, animationSeed: session.id)
                        .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(calloutTitle(for: session))
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                        Text(calloutSubtitle(for: session))
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.white.opacity(0.54))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                }

                if let preview = session.lastResponsePreview,
                   !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView(.vertical, showsIndicators: true) {
                        MarkdownResponseView(markdown: preview)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 5)
                    }
                    // A short answer still deserves a stable readable area;
                    // without a minimum, SwiftUI can compress this scroll
                    // view to a few pixels when the notch changes height.
                    .frame(height: responsePreviewHeight(for: preview))
                    .padding(.leading, 44)
                }

                HStack(spacing: 7) {
                    if session.lastResponsePreview?.isEmpty == false {
                        quickAction("Copy response", icon: "doc.on.doc") {
                            controller.copyResponse(sessionID: session.id)
                        }
                    }
                    quickAction("Open terminal", icon: "terminal") {
                        controller.focus(sessionID: session.id)
                    }
                    quickAction("Open hub", icon: "rectangle.expand.vertical") {
                        controller.showSessionBoard(focusing: session.id)
                    }
                    if controller.pendingCalloutCount > 0 {
                        Text("+\(controller.pendingCalloutCount) waiting")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 44)

                HStack(spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        ReplyTextView(
                            text: $calloutReply,
                            placeholder: "Reply to \(session.agent.displayName)…",
                            onBeginEditing: { controller.beginExplicitReply() },
                            onPasteImage: { image in
                                if let url = ScreenshotAttachmentStore.save(image) {
                                    calloutAttachments.append(url)
                                }
                            },
                            onSubmit: { sendCalloutReply($0, to: session.id) },
                            onCancel: { controller.dismissCallout() }
                        )
                        if calloutReply.isEmpty {
                            Text("Reply to \(session.agent.displayName)…")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.34))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 44)
                    .background(replyComposerSurface)

                    Button {
                        controller.beginExplicitReply()
                        // A non-activating notch panel deliberately does not
                        // become key for passive notifications. The document
                        // picker is an explicit interaction, so present it on
                        // the next run loop after making the panel key.
                        DispatchQueue.main.async {
                            controller.chooseAttachments { urls in
                                calloutAttachments.append(contentsOf: urls)
                            }
                        }
                    } label: {
                        Image(systemName: calloutAttachments.isEmpty ? "paperclip" : "paperclip.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(calloutAttachments.isEmpty ? .white.opacity(0.55) : .white.opacity(0.92))
                    .help(calloutAttachments.isEmpty ? "Attach files" : "Files attached")

                    Button {
                        sendCalloutReply(calloutReply, to: session.id)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.white.opacity(0.13)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(canSendCalloutReply ? 0.90 : 0.28))
                    .disabled(!canSendCalloutReply)
                    .help("Send reply")
                }
                if !calloutAttachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(calloutAttachments.indices, id: \.self) { index in
                            attachmentTag(
                                attachmentLabel(for: calloutAttachments[index], index: index),
                                icon: attachmentIcon(for: calloutAttachments[index])
                            ) {
                                calloutAttachments.remove(at: index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            }

            Button {
                controller.dismissCallout()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, topCameraInset + 7)
            .padding(.trailing, 14)
            .help("Dismiss notification")
        }
        .contentShape(Rectangle())
        .accessibilityLabel(
            "\(session.agent.displayName) finished in \(session.projectName). Reply or open all sessions."
        )
    }

    private func calloutTitle(for session: AgentSession) -> String {
        let agent = session.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = agent.flatMap { $0.isEmpty ? nil : $0 } ?? session.agent.displayName
        let name = session.sessionName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? session.projectName
        return "\(first) · \(label)"
    }

    private var replyComposerSurface: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.075))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.19), lineWidth: 0.9)
            }
    }

    private func sendCalloutReply(_ text: String, to sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendCalloutReply else { return }
        let message: String
        if !calloutAttachments.isEmpty {
            let lead = trimmed.isEmpty ? "Please inspect the attached file." : trimmed
            let paths = calloutAttachments.enumerated()
                .map { "\(attachmentLabel(for: $0.element, index: $0.offset)) attached locally: \($0.element.path)" }
                .joined(separator: "\n")
            message = "\(lead)\n\n\(paths)"
        } else {
            message = trimmed
        }
        isSendingCalloutReply = true
        controller.sendReply(message, to: sessionID) { success in
            isSendingCalloutReply = false
            if success {
                calloutReply = ""
                calloutAttachments = []
            }
        }
    }

    private var canSendCalloutReply: Bool {
        !isSendingCalloutReply
            && (!calloutReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !calloutAttachments.isEmpty)
    }

    private func attachmentTag(
        _ label: String,
        icon: String,
        remove: @escaping () -> Void
    ) -> some View {
        Button(action: remove) {
            Label(label, systemImage: icon)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.75))
        .help("Remove \(label)")
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

    private func quickAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.075)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.65))
    }

    private func calloutSubtitle(for session: AgentSession) -> String {
        switch session.state {
        case .needsApproval: return "Approval needed"
        case .hasQuestion: return "Your answer is needed"
        case .error: return "Agent needs attention"
        case .finished: return "Response ready"
        default: return session.currentActivity ?? session.state.displayName
        }
    }

    private func responsePreviewHeight(for preview: String) -> CGFloat {
        let visualLines = preview.components(separatedBy: .newlines).reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / 90)))
        }
        return min(250, max(38, 22 + CGFloat(visualLines) * 17))
    }

    private var compactSessions: [AgentSession] {
        Array(store.sessions.prefix(controller.compactVisibleSessionCount))
    }

    private func compactAccessibilityLabel(for session: AgentSession) -> String {
        "\(session.model ?? session.agent.displayName), \(session.projectName), \(session.state.displayName)"
    }

    private var sessionBoard: some View {
        VStack(spacing: 0) {
            boardHeader

            if store.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // A regular stack is intentional here: the board is a
                    // short live-session queue, not an unbounded feed. It
                    // also keeps a concrete width during the compact → board
                    // transition, which prevents rows from disappearing.
                    VStack(spacing: 0) {
                        ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                            SessionCardView(
                                controller: controller,
                                session: session,
                                expandedByDefault: controller.focusedSessionID == session.id
                            )
                            if index < store.sessions.count - 1 {
                                Divider()
                                    .overlay(Color.white.opacity(0.065))
                                    .padding(.leading, 65)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let message = controller.transientMessage {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.white.opacity(0.65))
                        .frame(width: 5, height: 5)
                    Text(message)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.035))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            boardFooter
        }
    }

    private var boardHeader: some View {
        ZStack(alignment: .top) {
            HStack {
                Text(store.activeCount == 1 ? "1 active" : "\(store.activeCount) active")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                Spacer()
                Button {
                    controller.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(NotchIconButtonStyle())
                .help("Settings")

                Button {
                    controller.collapsePanel()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(NotchIconButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
                .help("Collapse")
            }
            .frame(height: max(32, topCameraInset))

            AntonMark(size: 26, glows: true, compactAnimation: true)
                .padding(.top, topCameraInset + 8)
        }
        .padding(.horizontal, 18)
        .frame(height: topCameraInset + 50, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            AgentPixelGlyph(agent: .codex, state: .idle)
                .frame(width: 34, height: 34)
                .opacity(0.62)
            Text("No active agents")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
            Text("Start Claude Code or Codex in Terminal or iTerm.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.42))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var boardFooter: some View {
        HStack(spacing: 6) {
            Text(controller.preferences.shortcut.displayName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
            Text("toggle")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.25))
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
            Text("Local")
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.3))
        .padding(.horizontal, 20)
        .frame(height: 34)
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.055))
        }
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

/// An original pixel robot for Anton. Its small hover and blinking antenna give
/// it a living presence without adopting any third-party agent mark.
struct AntonMark: View {
    var size: CGFloat = 26
    var glows = true
    var compactAnimation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 8.0,
                paused: reduceMotion || !compactAnimation
            )
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion
                ? 0.18
                : time.truncatingRemainder(dividingBy: 2.1) / 2.1
            let routine = compactAnimation && !reduceMotion
                ? Int(time / 2.1).quotientAndRemainder(dividingBy: 4).remainder
                : 0
            let bob = compactAnimation && !reduceMotion
                ? sin(phase * .pi * 2) * size * (routine == 3 ? 0.075 : 0.050)
                : 0
            let antennaPulse = 0.78 + 0.22 * sin(phase * .pi * 2)
            let blink = reduceMotion || phase < 0.84 || phase > 0.92
            let tilt = compactAnimation && !reduceMotion
                ? sin(phase * .pi * 2) * (routine == 3 ? 2.4 : 1.3)
                : 0
            let squashX = routine == 2 ? 1 + sin(phase * .pi * 2) * 0.045 : 1
            let squashY = routine == 2 ? 1 - sin(phase * .pi * 2) * 0.035 : 1

            GeometryReader { proxy in
                let unit = min(proxy.size.width, proxy.size.height) / 7
                ZStack {
                    ForEach(Array(robotBlocks.enumerated()), id: \.offset) { _, block in
                        RoundedRectangle(cornerRadius: max(0.8, unit * 0.10), style: .continuous)
                            .fill(block.isEye ? Color.black.opacity(0.94) : Color.white.opacity(block.isAntenna ? antennaPulse : 0.96))
                            .frame(width: unit * block.width, height: blink && block.isEye ? unit * 0.28 : unit * block.height)
                            .position(
                                x: unit * (block.x + block.width / 2),
                                y: unit * (block.y + block.height / 2) + animatedYOffset(
                                    for: block,
                                    phase: phase,
                                    routine: routine,
                                    unit: unit
                                )
                            )
                            .offset(x: animatedXOffset(for: block, phase: phase, routine: routine, unit: unit))
                    }

                    if compactAnimation && !reduceMotion {
                        compactSignals(phase: phase, routine: routine, unit: unit)
                    }
                }
                .frame(width: unit * 7, height: unit * 7)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .offset(y: bob)
            .rotationEffect(.degrees(tilt))
            .scaleEffect(x: squashX, y: squashY)
        }
        .frame(width: size, height: size)
        .shadow(color: glows ? Color.white.opacity(0.52) : .clear, radius: size * 0.24)
        .accessibilityHidden(true)
    }

    private var robotBlocks: [AntonPixelBlock] {
        [
            AntonPixelBlock(x: 3, y: 0, width: 1, height: 1, isAntenna: true),
            AntonPixelBlock(x: 2, y: 1, width: 3, height: 1),
            AntonPixelBlock(x: 1, y: 2, width: 5, height: 3),
            AntonPixelBlock(x: 0, y: 3, width: 1, height: 1, isArm: true),
            AntonPixelBlock(x: 6, y: 3, width: 1, height: 1, isArm: true),
            AntonPixelBlock(x: 2, y: 3, width: 1, height: 1, isEye: true),
            AntonPixelBlock(x: 4, y: 3, width: 1, height: 1, isEye: true),
            AntonPixelBlock(x: 2, y: 5, width: 3, height: 1),
            AntonPixelBlock(x: 1, y: 6, width: 1, height: 1, isFoot: true),
            AntonPixelBlock(x: 5, y: 6, width: 1, height: 1, isFoot: true)
        ]
    }

    @ViewBuilder
    private func compactSignals(phase: Double, routine: Int, unit: CGFloat) -> some View {
        let leadingOpacity = max(0, sin(phase * .pi * 2))
        let trailingOpacity = max(0, sin((phase + 0.5) * .pi * 2))
        if routine == 0 || routine == 2 {
            Rectangle()
                .fill(Color.white.opacity(0.18 + 0.42 * leadingOpacity))
                .frame(width: max(1, unit * 0.45), height: max(1, unit * 0.45))
                .position(x: unit * 0.20, y: unit * 1.35)
            Rectangle()
                .fill(Color.white.opacity(0.16 + 0.38 * trailingOpacity))
                .frame(width: max(1, unit * 0.38), height: max(1, unit * 0.38))
                .position(x: unit * 6.80, y: unit * 2.15)
        } else if routine == 3 {
            Rectangle()
                .fill(Color.white.opacity(0.28 + 0.40 * leadingOpacity))
                .frame(width: max(1, unit * 0.36), height: max(1, unit * 0.36))
                .position(x: unit * 1.0, y: unit * 0.45)
            Rectangle()
                .fill(Color.white.opacity(0.20 + 0.34 * trailingOpacity))
                .frame(width: max(1, unit * 0.32), height: max(1, unit * 0.32))
                .position(x: unit * 6.0, y: unit * 0.75)
        }
    }

    private func animatedYOffset(
        for block: AntonPixelBlock,
        phase: Double,
        routine: Int,
        unit: CGFloat
    ) -> CGFloat {
        guard compactAnimation && !reduceMotion else { return 0 }
        if block.isAntenna {
            return sin(phase * .pi * (routine == 2 ? 6 : 4)) * unit * 0.30
        }
        if block.isArm, routine == 3 {
            let armOffset = block.x < 3 ? 0 : 0.5
            return -max(0, sin((phase + armOffset) * .pi * 2)) * unit * 0.95
        }
        if block.isFoot {
            let offset = block.x < 3 ? 0 : 0.5
            return max(0, sin((phase + offset) * .pi * 2)) * unit * 0.22
        }
        return 0
    }

    private func animatedXOffset(
        for block: AntonPixelBlock,
        phase: Double,
        routine: Int,
        unit: CGFloat
    ) -> CGFloat {
        guard compactAnimation && !reduceMotion, block.isEye else { return 0 }
        switch routine {
        case 1:
            return -unit * 0.20
        case 2:
            return unit * 0.20
        default:
            return sin(phase * .pi * 2) * unit * 0.05
        }
    }
}

private struct AntonPixelBlock {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    var isEye = false
    var isAntenna = false
    var isFoot = false
    var isArm = false
}

struct AgentPixelGlyph: View {
    let agent: AgentKind
    var state: AgentSessionState = .idle
    var animationSeed = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 8.0,
                paused: reduceMotion || !animatesCurrentState
            )
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let basePhase = time.truncatingRemainder(dividingBy: 1.8) / 1.8
            let phase = reduceMotion ? 0 : (basePhase + phaseOffset).truncatingRemainder(dividingBy: 1)
            let bodyBob = verticalBob(phase: phase)
            let tilt = rotation(phase: phase)
            let opacity = state == .disconnected ? 0.36 : state == .error ? errorOpacity(phase: phase) : 1.0

            GeometryReader { proxy in
                let unit = min(proxy.size.width, proxy.size.height) / 7
                ZStack {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        Rectangle()
                            .fill(block.isEye ? Color.black.opacity(0.88) : agentColor(agent))
                            .frame(
                                width: unit * block.width,
                                height: eyeHeight(for: block, unit: unit, phase: phase)
                            )
                            .position(
                                x: unit * (block.x + block.width / 2) + horizontalOffset(for: block, phase: phase, unit: unit),
                                y: unit * (block.y + block.height / 2) + bodyBob + verticalOffset(for: block, phase: phase, unit: unit)
                            )
                    }

                    stateSignals(phase: phase, unit: unit)
                }
                .frame(width: unit * 7, height: unit * 7)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .rotationEffect(.degrees(tilt))
                .opacity(opacity)
            }
        }
        .shadow(color: agentColor(agent).opacity(state.needsUser ? 0.48 : 0.26), radius: state.needsUser ? 7 : 5)
        .accessibilityHidden(true)
    }

    private var animatesCurrentState: Bool {
        switch state {
        case .working, .needsApproval, .hasQuestion, .error:
            return true
        case .finished, .idle, .disconnected:
            return false
        }
    }

    private var phaseOffset: Double {
        var value = 0
        for scalar in animationSeed.unicodeScalars {
            value = (value * 31 + Int(scalar.value)) % 997
        }
        return Double(value) / 997
    }

    /// Each state has a deliberately distinct movement language: working
    /// alternates its arms, approvals beacon, questions look around, and a
    /// completed turn gives a restrained bounce. Motion is fully disabled by
    /// the system Reduce Motion preference.
    private func verticalBob(phase: Double) -> CGFloat {
        switch state {
        case .working: return sin(phase * .pi * 4) * 0.34
        case .finished: return -max(0, sin(phase * .pi * 2)) * 0.95
        case .idle: return sin(phase * .pi * 2) * 0.16
        case .hasQuestion: return sin(phase * .pi * 2) * 0.22
        case .needsApproval: return 0
        case .error: return sin(phase * .pi * 12) * 0.18
        case .disconnected: return 0
        }
    }

    private func rotation(phase: Double) -> Double {
        switch state {
        case .hasQuestion: return sin(phase * .pi * 2) * 5
        case .finished: return sin(phase * .pi * 2) * 2.5
        case .error: return sin(phase * .pi * 8) * 1.8
        default: return 0
        }
    }

    private func verticalOffset(for block: PixelBlock, phase: Double, unit: CGFloat) -> CGFloat {
        switch state {
        case .working where block.isArm:
            let offset = block.x < 3 ? 0.0 : 0.5
            return -max(0, sin((phase + offset) * .pi * 2)) * unit * 0.72
        case .finished where block.isArm:
            return -max(0, sin(phase * .pi * 2)) * unit * 0.48
        case .needsApproval where block.isArm:
            return -abs(sin(phase * .pi * 3)) * unit * 0.36
        default:
            return 0
        }
    }

    private func horizontalOffset(for block: PixelBlock, phase: Double, unit: CGFloat) -> CGFloat {
        guard block.isEye else { return 0 }
        switch state {
        case .hasQuestion: return sin(phase * .pi * 2) * unit * 0.30
        case .working: return sin(phase * .pi * 4) * unit * 0.10
        case .error: return sin(phase * .pi * 10) * unit * 0.12
        default: return 0
        }
    }

    private func eyeHeight(for block: PixelBlock, unit: CGFloat, phase: Double) -> CGFloat {
        guard block.isEye else { return unit * block.height }
        let blink = state == .idle && phase > 0.82 && phase < 0.89
        return blink ? max(1, unit * 0.18) : unit * block.height
    }

    @ViewBuilder
    private func stateSignals(phase: Double, unit: CGFloat) -> some View {
        switch state {
        case .working:
            let keyPhase = max(0, sin(phase * .pi * 4))
            Rectangle()
                .fill(Color.white.opacity(0.30))
                .frame(width: unit * 3.8, height: unit * 1.55)
                .position(x: unit * 3.5, y: unit * 5.68)
            Rectangle()
                .fill(Color.black.opacity(0.88))
                .frame(width: unit * 3.05, height: unit * 0.82)
                .position(x: unit * 3.5, y: unit * 5.48)
            Rectangle()
                .fill(agentColor(agent).opacity(0.88))
                .frame(width: unit * 0.82, height: unit * 0.24)
                .position(x: unit * (2.6 + keyPhase * 1.8), y: unit * 5.48)
            Rectangle()
                .fill(Color.white.opacity(0.44))
                .frame(width: unit * 4.25, height: max(1, unit * 0.34))
                .position(x: unit * 3.5, y: unit * 6.62)
        case .needsApproval:
            let beacon = 0.22 + 0.68 * max(0, sin(phase * .pi * 2))
            Rectangle()
                .fill(Color.orange.opacity(beacon))
                .frame(width: max(1, unit * 0.66), height: max(1, unit * 0.66))
                .position(x: unit * 3.5, y: unit * 0.25)
            Rectangle()
                .fill(Color.orange.opacity(beacon * 0.72))
                .frame(width: max(1, unit * 0.46), height: max(1, unit * 0.46))
                .position(x: unit * 0.45, y: unit * 1.15)
        case .hasQuestion:
            let dot = 0.26 + 0.58 * max(0, sin(phase * .pi * 2))
            Rectangle()
                .fill(Color(red: 0.82, green: 0.61, blue: 1).opacity(dot))
                .frame(width: max(1, unit * 0.50), height: max(1, unit * 0.50))
                .position(x: unit * 6.55, y: unit * 0.72)
        case .finished:
            let sparkle = max(0, sin(phase * .pi * 2))
            Rectangle()
                .fill(Color.white.opacity(0.26 + 0.62 * sparkle))
                .frame(width: max(1, unit * 0.42), height: max(1, unit * 0.42))
                .position(x: unit * 0.45, y: unit * 0.85)
            Rectangle()
                .fill(Color.white.opacity(0.14 + 0.42 * sparkle))
                .frame(width: max(1, unit * 0.32), height: max(1, unit * 0.32))
                .position(x: unit * 6.45, y: unit * 1.35)
        case .error:
            Rectangle()
                .fill(Color.red.opacity(0.30 + 0.38 * max(0, sin(phase * .pi * 6))))
                .frame(width: max(1, unit * 0.42), height: max(1, unit * 0.42))
                .position(x: unit * 6.5, y: unit * 0.70)
        default:
            EmptyView()
        }
    }

    private func errorOpacity(phase: Double) -> Double {
        phase > 0.72 && phase < 0.80 ? 0.50 : 1.0
    }

    private var blocks: [PixelBlock] {
        if agent == .claude {
            return [
                PixelBlock(x: 0, y: 0, width: 2, height: 2),
                PixelBlock(x: 5, y: 0, width: 2, height: 2),
                PixelBlock(x: 1, y: 1, width: 5, height: 5),
                PixelBlock(x: 0, y: 3, width: 1, height: 2, isArm: true),
                PixelBlock(x: 6, y: 3, width: 1, height: 2, isArm: true),
                PixelBlock(x: 2, y: 3, width: 1, height: 1, isEye: true),
                PixelBlock(x: 4, y: 3, width: 1, height: 1, isEye: true),
                PixelBlock(x: 2, y: 6, width: 1, height: 1),
                PixelBlock(x: 4, y: 6, width: 1, height: 1)
            ]
        }
        return [
            PixelBlock(x: 1, y: 1, width: 5, height: 5),
            PixelBlock(x: 2, y: 0, width: 3, height: 1),
            PixelBlock(x: 0, y: 2, width: 1, height: 3, isArm: true),
            PixelBlock(x: 6, y: 2, width: 1, height: 3, isArm: true),
            PixelBlock(x: 2, y: 3, width: 1, height: 1, isEye: true),
            PixelBlock(x: 4, y: 3, width: 1, height: 1, isEye: true),
            PixelBlock(x: 2, y: 5, width: 3, height: 1),
            PixelBlock(x: 1, y: 6, width: 1, height: 1),
            PixelBlock(x: 5, y: 6, width: 1, height: 1)
        ]
    }
}

private struct PixelBlock {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    var isEye = false
    var isArm = false
}

private struct NotchSurface: Shape {
    var expanded: Bool

    var animatableData: CGFloat {
        get { expanded ? 1 : 0 }
        set { expanded = newValue > 0.5 }
    }

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = expanded ? 22 : 15
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.maxY - radius),
            control: CGPoint(x: 0, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

struct NotchIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.95 : 0.52))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }
}

func agentColor(_ agent: AgentKind) -> Color {
    switch agent {
    case .claude:
        return Color(red: 0.98, green: 0.57, blue: 0.36)
    case .codex:
        return Color(red: 0.48, green: 0.68, blue: 1)
    }
}
