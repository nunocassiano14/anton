# Known limitations

- Version 1 supports Apple Silicon and macOS 14 or later only.
- Supported terminals are Terminal.app and iTerm2. tmux, SSH-owned remote terminals, IDE terminals, and other terminal emulators are out of scope.
- Supported agents are Claude Code and Codex CLI only.
- Codex requires a one-time manual `/hooks` trust review after installation or any helper-path change.
- Codex does not currently expose a dedicated direct-answer output for its `request_user_input` tool. Anton returns the answer as model-visible blocking feedback for that exact tool call.
- Interactive hook waits are capped at roughly ten minutes. An unanswered approval or question eventually times out and returns control to the agent's normal failure path.
- Live state is intentionally not persisted. After Anton restarts, already-running Terminal/iTerm Codex and Claude Code processes are rediscovered locally; detailed hook-owned context returns on their next lifecycle event.
- Unexpected process exit is detected only when the helper can identify the agent PID in its parent chain. Otherwise, `SessionEnd` or explicit dismissal clears the session.
- A tab closed or moved to a different terminal process cannot be targeted afterward.
- The top-center compact panel is the visual fallback on Macs without a physical notch; the menu-bar interface remains available, but version 1 does not use a separate NSPopover.
- Approval cards show the current action and command/description, not a full diff review.
- Development builds are ad-hoc signed and not notarized. macOS Automation or Accessibility consent can need renewal when the signature changes.
- Public App Store distribution, remote access, multi-Mac synchronization, analytics, accounts, and payments are intentionally absent.
