import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?
    var allowsKeyboardFocus = false

    // A callout is informational until the user deliberately interacts with
    // it. This keeps the current terminal as the key window while agents work.
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class NotchPanelController: NSWindowController {
    private weak var controller: AppController?
    private var screenObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var hiddenForSystemModal = false

    init(controller: AppController) {
        self.controller = controller
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.onEscape = { [weak controller] in controller?.collapsePanel() }
        panel.contentViewController = NSHostingController(
            rootView: NotchRootView(controller: controller)
        )
        super.init(window: panel)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateFrame(expanded: controller.isExpanded, animated: false)
            }
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureOverlayVisible()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureOverlayVisible()
            }
        }
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureOverlayVisible()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let applicationActivationObserver {
            NotificationCenter.default.removeObserver(applicationActivationObserver)
        }
    }

    func showCompact() {
        (window as? NotchPanel)?.allowsKeyboardFocus = false
        updateFrame(expanded: false, animated: false)
        window?.orderFrontRegardless()
        window?.resignKey()
    }

    func refreshCompactFrame() {
        guard controller?.isExpanded == false else { return }
        updateFrame(expanded: false, animated: true)
    }

    func setExpanded(_ expanded: Bool) {
        // Opening the board or a callout is still passive. The panel becomes
        // key only through `focusForExplicitReply`, after the user selected
        // Reply. This prevents a completion callout from intercepting typing
        // in Terminal, iTerm, Wispr Flow, or any other foreground app.
        (window as? NotchPanel)?.allowsKeyboardFocus = false
        updateFrame(expanded: expanded, animated: true)
        window?.orderFrontRegardless()
        if !expanded {
            window?.resignKey()
        }
    }

    /// Only explicit reply/edit actions should move keyboard focus away from
    /// the terminal. Passive callouts and approval cards never invoke this.
    func focusForExplicitReply() {
        guard let panel = window as? NotchPanel else { return }
        panel.allowsKeyboardFocus = true
        panel.makeKeyAndOrderFront(nil)
    }

    /// Temporarily gets out of the way of a system modal panel (such as
    /// NSOpenPanel). This is the only supported reason for the overlay not to
    /// be on screen while Anton remains running.
    func hideForSystemModal() {
        hiddenForSystemModal = true
        window?.orderOut(nil)
    }

    func restoreAfterSystemModal() {
        hiddenForSystemModal = false
        ensureOverlayVisible()
        focusForExplicitReply()
    }

    /// Keep Anton visual-only: bringing its panel forward never makes it key,
    /// so users can continue typing in the foreground app uninterrupted.
    func ensureOverlayVisible() {
        guard !hiddenForSystemModal else { return }
        guard let panel = window as? NotchPanel else { return }
        // Activating Anton is part of an explicit click into the reply
        // editor. The application/workspace activation observers fire for
        // that transition too; never let them immediately undo the user's
        // focus. Once another app becomes key, `isKeyWindow` is false and the
        // overlay returns to its passive, non-key behaviour.
        if panel.allowsKeyboardFocus && panel.isKeyWindow {
            panel.orderFrontRegardless()
            return
        }
        panel.allowsKeyboardFocus = false
        window?.orderFrontRegardless()
        window?.resignKey()
    }

    private func updateFrame(expanded: Bool, animated: Bool) {
        guard let window, let screen = primaryScreen() else { return }
        // The board is a working surface: wider rows preserve full agent
        // replies, Markdown tables and the reply controls without forcing
        // every useful line into a narrow column under the camera.
        let width: CGFloat
        let originX: CGFloat
        if expanded {
            width = min(820, screen.visibleFrame.width - 48)
            originX = screen.frame.midX - width / 2
        } else {
            let geometry = compactGeometry(for: screen)
            width = geometry.width
            originX = geometry.minX
            controller?.updateCompactCameraWidth(geometry.cameraWidth)
        }
        let height: CGFloat
        if !expanded {
            height = max(46, screen.safeAreaInsets.top + 14)
        } else if controller?.calloutSessionID != nil {
            // A callout includes the agent's latest answer, not only a status
            // label, so there is room for a short readable preview.
            let contentHeight = controller?.preferredCalloutBodyHeight ?? 360
            // The measured SwiftUI callout already includes its camera inset;
            // adding screen safe-area space again creates blank black space.
            height = min(screen.visibleFrame.height - 90, contentHeight)
        } else {
            height = min(780, screen.visibleFrame.height - 50)
        }
        let frame = NSRect(
            x: originX,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        window.setFrame(frame, display: true, animate: animated)
    }

    /// Keep the camera housing covered while sizing its two wings
    /// independently: only as much room as the live agent cluster needs on
    /// the left and the exact icon allowance for Anton on the right.
    private func compactGeometry(
        for screen: NSScreen
    ) -> (minX: CGFloat, width: CGFloat, cameraWidth: CGFloat) {
        let cameraMinX: CGFloat
        let cameraMaxX: CGFloat
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX
        {
            cameraMinX = leftArea.maxX
            cameraMaxX = rightArea.minX
        } else {
            // External displays have no physical housing. Preserve the same
            // visual centre gap so the surface keeps its notch silhouette.
            cameraMinX = screen.frame.midX - 75
            cameraMaxX = screen.frame.midX + 75
        }

        let antonWing = controller?.compactAntonWingWidth ?? 47
        let agentsWing = controller?.compactAgentsWingWidth ?? 28
        let width = antonWing + (cameraMaxX - cameraMinX) + agentsWing
        let unclampedMinX = cameraMinX - agentsWing
        let minX = min(
            max(unclampedMinX, screen.frame.minX + 24),
            screen.frame.maxX - 24 - width
        )
        return (minX, width, cameraMaxX - cameraMinX)
    }

    private func primaryScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == mainDisplayID
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
