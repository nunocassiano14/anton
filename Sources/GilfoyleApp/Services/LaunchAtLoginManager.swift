import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Anton now uses one launchd supervisor. This only removes the legacy
    /// SMAppService registration left by older local builds.
    func disableLegacyRegistrationIfNeeded() {
        guard isEnabled else { return }
        do {
            try SMAppService.mainApp.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
