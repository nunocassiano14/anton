import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A manually launched copy is immediately replaced by the local
        // launchd-supervised process. The latter has the same app bundle and
        // user scope, but can restart Anton after an abnormal exit.
        if LocalOverlaySupervisor.relaunchUnderSupervisorIfNeeded() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        controller.start()

        controller.sessionStore.$sessions
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AntonStatusMark.image
        statusItem.button?.toolTip = "Anton"
        self.statusItem = statusItem
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let status = NSMenuItem(
            title: "\(controller.sessionStore.activeCount) active · \(controller.sessionStore.needsUserCount) need you",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Open Anton",
            action: #selector(openPanel),
            keyEquivalent: ""
        ).target = self
        let newSession = menu.addItem(
            withTitle: "New Session…",
            action: #selector(openNewSession),
            keyEquivalent: "n"
        )
        newSession.target = self
        newSession.keyEquivalentModifierMask = [.command, .option]
        let resumeSession = menu.addItem(
            withTitle: "Resume Session…",
            action: #selector(openResumeSession),
            keyEquivalent: "r"
        )
        resumeSession.target = self
        resumeSession.keyEquivalentModifierMask = [.command, .option]
        let resumeLatest = menu.addItem(
            withTitle: "Resume Latest",
            action: #selector(resumeLatestSession),
            keyEquivalent: "r"
        )
        resumeLatest.target = self
        resumeLatest.keyEquivalentModifierMask = [.command, .option, .shift]

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        menu.addItem(
            withTitle: "Run Setup Again…",
            action: #selector(openOnboarding),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Anton",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        statusItem.menu = menu
    }

    @objc private func openPanel() {
        controller.showSessionBoard()
    }

    @objc private func openNewSession() {
        controller.showSessionLauncher(mode: .new)
    }

    @objc private func openResumeSession() {
        controller.showSessionLauncher(mode: .resume)
    }

    @objc private func resumeLatestSession() {
        controller.resumeLatestSession()
    }

    @objc private func openSettings() {
        controller.showSettings()
    }

    @objc private func openOnboarding() {
        controller.showOnboarding()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private enum AntonStatusMark {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.labelColor.setFill()
        let unit: CGFloat = 2
        let blocks: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (3, 0, 1, 1), (2, 1, 3, 1), (1, 2, 5, 3),
            (0, 3, 1, 1), (6, 3, 1, 1), (2, 5, 3, 1),
            (1, 6, 1, 1), (5, 6, 1, 1)
        ]
        for block in blocks {
            NSBezierPath(
                roundedRect: NSRect(
                    x: 2 + block.0 * unit,
                    y: 2 + (6 - block.1) * unit,
                    width: block.2 * unit,
                    height: block.3 * unit
                ),
                xRadius: 0.6,
                yRadius: 0.6
            ).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}
