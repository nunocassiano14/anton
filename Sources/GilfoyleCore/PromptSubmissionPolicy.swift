import Foundation

/// Keeps ordinary prompts away from terminal-owned interactive controls.
///
/// Claude Code and Codex render approvals and `request_user_input` pickers in
/// the same TTY as their normal composer. Sending an unrelated queued prompt
/// while one of those controls is active can select an option, overwrite the
/// picker, or leave text behind for the next turn. The lifecycle interaction
/// is therefore the authoritative gate for every free-form submission.
public enum PromptSubmissionPolicy {
    public static func canSubmitFreeformPrompt(to session: AgentSession) -> Bool {
        guard session.interaction == nil else { return false }
        return session.state == .finished
            || session.state == .idle
            || session.state == .error
    }

    public static func canDeliverQueuedPrompt(to session: AgentSession) -> Bool {
        session.interaction == nil && session.state == .finished
    }
}
