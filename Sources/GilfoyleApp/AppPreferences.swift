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

    @Published var launchAtLoginPreference: Bool {
        didSet {
            stored.launchAtLoginPreference = launchAtLoginPreference
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
        self.launchAtLoginPreference = stored.launchAtLoginPreference
        try? repository.save(stored)
    }

    private func persist() {
        try? repository.save(stored)
    }
}
