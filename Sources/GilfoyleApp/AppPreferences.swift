import Combine
import Foundation
import GilfoyleCore

@MainActor
final class AppPreferences: ObservableObject {
    private let repository: PreferencesRepository
    private var stored: StoredPreferences

    @Published var shortcut: ShortcutConfiguration {
        didSet {
            stored.shortcut = shortcut
            persist()
        }
    }

    @Published var onboardingComplete: Bool {
        didSet {
            stored.onboardingComplete = onboardingComplete
            persist()
        }
    }

    @Published var lastLaunchAgent: AgentKind? {
        didSet {
            stored.lastLaunchAgent = lastLaunchAgent
            persist()
        }
    }

    @Published var lastLaunchWorkspace: String? {
        didSet {
            stored.lastLaunchWorkspace = lastLaunchWorkspace
            persist()
        }
    }

    @Published var lastLaunchTerminal: TerminalKind? {
        didSet {
            stored.lastLaunchTerminal = lastLaunchTerminal
            persist()
        }
    }

    init(defaults: UserDefaults = .standard) {
        let repository = PreferencesRepository(defaults: defaults)
        let stored = repository.load()
        self.repository = repository
        self.stored = stored
        self.shortcut = stored.shortcut
        self.onboardingComplete = stored.onboardingComplete
        self.lastLaunchAgent = stored.lastLaunchAgent
        self.lastLaunchWorkspace = stored.lastLaunchWorkspace
        self.lastLaunchTerminal = stored.lastLaunchTerminal
        try? repository.save(stored)
    }

    private func persist() {
        try? repository.save(stored)
    }
}
