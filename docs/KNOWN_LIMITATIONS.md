# Known limitations

- Version 1 supports Apple Silicon and macOS 14 or later only.
- Supported terminals are Terminal.app and iTerm2. tmux, SSH-owned remote terminals, IDE terminals, and other terminal emulators are out of scope.
- Supported agents are Claude Code and Codex CLI only.
- Resume discovery depends on the agents' current local metadata formats.
  Unknown or malformed future rows are skipped safely; a compatibility fallback
  may show a Codex title and session ID without a workspace, which cannot be
  resumed until the original workspace is known locally.
- The launcher intentionally opens a real Terminal/iTerm surface only after
  New, Resume, or Fork is confirmed. Headless agent sessions are out of scope.
- Codex requires a one-time manual `/hooks` trust review after installation or any helper-path change.
- Codex does not currently expose a dedicated direct-answer output for its `request_user_input` tool. Anton returns the answer as model-visible blocking feedback for that exact tool call.
- Interactive hook waits are capped at roughly ten minutes. An unanswered approval or question eventually times out and returns control to the agent's normal failure path.
- Live state is intentionally not persisted. After Anton restarts, already-running Terminal/iTerm Codex and Claude Code processes are rediscovered locally; detailed hook-owned context returns on their next lifecycle event.
- Hook-owned processes are removed immediately on exit. A session known only
  through local discovery can take up to five seconds to disappear and close
  its terminal tab.
- In a multi-tab Terminal/iTerm window, automatic removal uses a clean `exit`
  on the exact TTY/session. A custom terminal profile configured to keep
  cleanly exited shells visible can therefore leave an inert tab behind; Anton
  never closes neighbouring tabs to force the result.
- A tab closed or moved to a different terminal process cannot be targeted afterward.
- The top-center compact panel is the visual fallback on Macs without a physical notch; the menu-bar interface remains available, but version 1 does not use a separate NSPopover.
- Approval cards show the current action and command/description, not a full diff review.
- Development builds are ad-hoc signed and not notarized. macOS Automation consent can need renewal when the signature changes.
- Public App Store distribution, remote access, multi-Mac synchronization, analytics, accounts, and payments are intentionally absent.
