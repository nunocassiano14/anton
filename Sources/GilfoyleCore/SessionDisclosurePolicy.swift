import Foundation

/// Keeps attention states discoverable without trapping their cards open.
/// A new response/question opens once; after that, the user's chevron click is
/// authoritative until the session enters another attention state.
public enum SessionDisclosurePolicy {
    public static func initial(
        expandedByDefault: Bool,
        state: AgentSessionState,
        forceOpen: Bool = false
    ) -> Bool {
        expandedByDefault || state.needsUser || forceOpen
    }

    public static func toggled(_ current: Bool) -> Bool {
        !current
    }

    public static func afterStateChange(
        current: Bool,
        state: AgentSessionState
    ) -> Bool {
        state.needsUser ? true : current
    }
}
