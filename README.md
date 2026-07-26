# Anton

Anton is a native, local-only macOS companion for Claude Code and Codex CLI. It keeps live coding-agent sessions visible in a compact notch panel, shows a visual callout when a main turn finishes, and routes replies, approvals, and structured answers back to the exact originating terminal session.

The initial release supports Apple Silicon, macOS 14 or later, Terminal.app, iTerm2, Claude Code, and Codex CLI. It does not require a wrapper command: continue starting agents with `claude` and `codex`.

## What is implemented

- Compact primary-display notch surface, response callout, and expandable live session board
- Menu-bar status, Settings, setup, and quit controls
- Configurable global shortcut, `⌥⌘G` by default
- Claude Code and Codex lifecycle adapters using official hooks
- Exact Terminal.app targeting by TTY
- Exact iTerm2 targeting by session unique ID, with TTY fallback
- Native reply editor compatible with normal macOS dictation and Wispr Flow
- Enter to send, Shift+Enter for a newline, and Escape to close
- Allow and Deny actions for approval requests
- Choice buttons and free-form fields for structured questions
- Main-turn completion detection with a focused visual callout
- In-memory session state only; no transcript database or prompt history
- Authenticated Unix-domain socket with private `0600` permissions
- Idempotent, backed-up, selectively removable agent integrations
- Launch at Login using `SMAppService`
- Event-driven process-exit monitoring without polling
- Accessibility labels and keyboard-accessible native controls

## Build

Requirements:

- Apple Silicon Mac
- macOS 14 or later
- Swift 6 toolchain or full Xcode

Build the Swift package:

```sh
swift build -c debug
```

Build an ad-hoc signed application bundle:

```sh
./Scripts/build-app.sh
```

The result is `build/Anton.app`.

Install a local development copy in `~/Applications`:

```sh
./Scripts/install-local.sh
```

The repository also contains `Anton.xcodeproj`. Its `Anton` scheme invokes the same deterministic app-bundle build, and its `AntonTests` scheme runs the standalone suite. A full Xcode installation is required to use `xcodebuild` or the Xcode UI.

## Run and onboard

Open `build/Anton.app` or the installed copy. On first launch:

1. Review the detected Claude Code, Codex, Terminal, and iTerm installations.
2. Grant Accessibility when macOS opens System Settings.
3. Request Automation access for Terminal and iTerm. macOS shows one consent dialog for each application.
4. Install Claude Code hooks.
5. Install Codex hooks.
6. Start Codex and run `/hooks` once to review and trust the exact Anton hook definition.
7. Choose whether Anton should launch at login, then finish setup.

Sessions with installed hooks provide the richest live detail. Anton also discovers already-open Codex and Claude Code processes in Terminal and iTerm locally, including their current local lifecycle state where available.

## Daily use

Start agents normally:

```sh
claude
codex
```

Click the compact notch surface or press the configured global shortcut to open the board. Each flat session row identifies the agent, project, model, terminal, state, activity, start time, and last action when the hook exposes that information.

When a main turn finishes, Anton expands into a focused visual callout. Choose Reply to reveal that session's native editor, type or dictate, and press Enter. Anton resolves the stored Terminal TTY or iTerm unique session ID before sending, so it never targets whichever terminal happens to be focused.

Approval and question hooks remain blocked while the card awaits a response. Anton sends only the explicit Allow, Deny, Cancel, or answer selected by the user; it does not weaken Claude Code or Codex sandbox policy.

## Tests

Run the deterministic standalone suite:

```sh
./Scripts/test.sh
```

The suite exercises state transitions, visual completion signals, event privacy, agent adapters, exact terminal identity, reply and interaction routing, settings persistence, hook output schemas, configuration preservation and removal, and authenticated local IPC.

The same cases are also expressed with Swift Testing under `Tests/AntonCoreTests`. On a complete Xcode installation, `Scripts/test.sh` additionally runs the standard SwiftPM test suite.

## Privacy

Anton has no accounts, analytics, telemetry, subscription code, cloud backend, HTTP client, or runtime network requests. Its only runtime communication channel is a private Unix-domain socket under:

```text
~/Library/Application Support/Anton/
```

The hook helper intentionally drops prompt text and transcript paths. It forwards only lifecycle metadata plus the current approval or question payload when the notch must render an interaction. Live sessions stay in memory. Preferences, the IPC token, and recoverable configuration backups are the only persistent Anton data.

See [Privacy](docs/PRIVACY.md) and [Architecture](docs/ARCHITECTURE.md) for the exact data flow.

## Removing integrations

Open Settings and choose Remove beside Claude Code or Codex. The remover deletes only command handlers containing Anton's bundled helper marker. It preserves unrelated settings, hook groups, and commands.

Every material edit to an existing configuration creates a timestamped backup under:

```text
~/Library/Application Support/Anton/Backups/
```

Removing the integration does not delete backups or application preferences.

## Troubleshooting

### A session does not appear

- Confirm the relevant integration says Ready in Settings.
- For Codex, run `/hooks` and trust the current Anton hook.
- Restart sessions that were open before hook installation.
- Ensure Anton is running before starting the next turn.
- Confirm the agent is running in Terminal.app or iTerm2, not tmux or another terminal.

### Reply or focus fails

- Open System Settings → Privacy & Security → Automation and allow Anton to control Terminal and iTerm.
- Open System Settings → Privacy & Security → Accessibility and enable Anton.
- If the app was rebuilt with a new ad-hoc signature, macOS may require permission again.
- A session whose original tab was closed cannot be retargeted; dismiss its card.

### Codex asks in the terminal instead of the notch

- Run `/hooks` and verify that the user-level `~/.codex/hooks.json` entry is enabled and trusted.
- A changed helper path changes the hook hash. Repair the integration in Settings, then review it again with `/hooks`.

### Launch at Login fails

Launch-at-login registration is most reliable when Anton is installed in `~/Applications` or `/Applications`. Install the local build with `./Scripts/install-local.sh`, reopen it from that location, and enable the toggle again.

## Further documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Agent integrations](docs/INTEGRATIONS.md)
- [Privacy](docs/PRIVACY.md)
- [Validation](docs/VALIDATION.md)
- [Known limitations](docs/KNOWN_LIMITATIONS.md)
