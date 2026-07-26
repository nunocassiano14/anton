import ServiceManagement

enum LaunchAtLoginManager {
    /// Anton now uses one launchd supervisor. This only removes the legacy
    /// SMAppService registration left by older local builds.
    static func disableLegacyRegistrationIfNeeded() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
    }
}
