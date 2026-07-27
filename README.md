# Anton

Anton is a native, local-only macOS companion for Claude Code and Codex CLI. It keeps live coding-agent sessions visible in a compact notch panel, shows a visual callout when a main turn finishes, and routes replies, approvals, and structured answers back to the exact originating terminal session.

The initial release supports Apple Silicon, macOS 14 or later, Terminal.app, iTerm2, Claude Code, and Codex CLI. It does not require a wrapper command: continue starting agents with `claude` and `codex`.

## What is implemented

- Compact primary-display notch surface, response callout, and expandable live session board
- Menu-bar status, Settings, setup, and quit controls
- Global shortcut, `⌥⌘G`
- Unified session launcher: choose Claude Code or Codex, then New or Existing
- New-session composer with advanced workspace, branch, name, and terminal options
- Git branch picker combining the current repo with recent Claude/Codex branches
- Named Existing-session browser backed by local Claude and Codex history
- Launcher shortcuts: `⌥⌘N` New, `⌥⌘R` Resume, `⌥⇧⌘R` Resume latest
- Claude/Codex resume and fork commands with running-session detection
- Claude Code and Codex lifecycle adapters using official hooks
- Exact Terminal.app targeting by TTY
- Exact iTerm2 targeting by session unique ID, with TTY fallback
- Native reply editor compatible with normal macOS dictation and Wispr Flow
- Enter to send, Shift+Enter for a newline, and Escape to close
- Allow and Deny actions for approval requests
- Choice buttons and free-form fields for structured questions
- Main-turn completion detection with a focused visual callout
- File and image attachments routed as explicit local paths
- In-memory session state only; no transcript database or prompt history
- Authenticated Unix-domain socket with private `0600` permissions
- Idempotent, backed-up, selectively removable agent integrations
- Per-user launchd supervision: restart after abnormal exit, stay closed after Quit
- Event-driven process-exit monitoring plus a cached low-frequency discovery fallback
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
2. Request Automation access for Terminal and iTerm. macOS shows one consent dialog for each application.
3. Install Claude Code hooks.
4. Install Codex hooks.
5. Start Codex and run `/hooks` once to review and trust the exact Anton hook definition.
6. Finish setup. Anton's local supervisor starts it at login and restarts only abnormal exits.

Sessions with installed hooks provide the richest live detail. Anton also discovers already-open Codex and Claude Code processes in Terminal and iTerm locally, including their current local lifecycle state where available.

## Daily use

Start agents normally:

```sh
claude
codex
```

Or press `⌥⌘N` to open Anton's session launcher. First choose Claude Code or
Codex, then choose New or Existing. New keeps the task prompt visible and puts
workspace, Git branch, optional name, and terminal under Options. The branch
menu combines local branches in the selected repository with recent branch
metadata from Claude and Codex sessions. Anton safely switches the workspace,
opens the new terminal surface, waits for the official `SessionStart` hook,
and only then submits the prompt to that exact session. The prompt is never
placed in shell arguments.

Choose Existing, or press `⌥⌘R`, to browse named local sessions in the same
launcher. `⌥⇧⌘R` resumes the most recent one. Anton reads Claude's local history
index and Codex's local thread database directly; opening the browser does not
start Terminal. Previews are hidden until explicitly enabled. A session that
is already running is opened on the live board rather than launched twice.
Resume and Fork create a terminal surface only after the user chooses the
action.

Click the compact notch surface or press `⌥⌘G` to open the board. Each flat session row identifies the agent, project, model, terminal, state, activity, start time, and last action when the hook exposes that information.

When a main turn finishes, Anton expands into a focused visual callout. Type or dictate in that session's native editor and press Enter. You can also paste an image or attach a local file. Anton resolves the stored Terminal TTY or iTerm unique session ID before sending, so it never targets whichever terminal happens to be focused. It waits for the agent's lifecycle acknowledgement and retries a background-only Return if Terminal pasted the prompt without submitting it. If another agent finishes while a callout is visible, Anton queues it; urgent approvals and questions move ahead of normal completions.

Approval and question hooks remain blocked while the card awaits a response. Anton sends only the explicit Allow, Deny, Cancel, or answer selected by the user; it does not weaken Claude Code or Codex sandbox policy.

When an agent process ends, Anton cancels any pending interaction, removes the
session from the board, and closes only its stored Terminal/iTerm surface.
It never substitutes the currently selected tab.

## Tests

Run the deterministic standalone suite:

```sh
./Scripts/test.sh
```

The suite exercises state transitions, visual completion signals, local session
history parsing, safe New/Resume/Fork command construction, event privacy,
agent adapters, exact terminal identity, reply and interaction routing,
settings persistence, hook output schemas, configuration preservation and
removal, and authenticated local IPC.

The same cases are also expressed with Swift Testing under `Tests/GilfoyleCoreTests`. On a complete Xcode installation, `Scripts/test.sh` additionally runs the standard SwiftPM test suite.

## Privacy

Anton has no accounts, analytics, telemetry, subscription code, cloud backend,
HTTP client, or runtime network requests. The Resume browser performs read-only
access to Claude and Codex metadata that already exists on the Mac; Anton does
not copy it into its own database. Its only runtime communication channel is a
private Unix-domain socket under:

```text
~/Library/Application Support/Anton/
```

The hook helper never forwards prompt text or transcript paths. When Claude omits its final response from a Stop event, the helper reads only a bounded tail of the referenced local transcript, extracts the latest assistant response, and forwards that preview through Anton's private local socket. Live sessions stay in memory. Preferences, the IPC token, and recoverable configuration backups are the only persistent Anton data.

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
- If the app was rebuilt with a new ad-hoc signature, macOS may require permission again.
- A session whose original tab was closed cannot be retargeted; dismiss its card.

### Codex asks in the terminal instead of the notch

- Run `/hooks` and verify that the user-level `~/.codex/hooks.json` entry is enabled and trusted.
- A changed helper path changes the hook hash. Repair the integration in Settings, then review it again with `/hooks`.

### Anton does not restart after a crash

The supervisor is registered from the app's current location. Install the local build with `./Scripts/install-local.sh`; the script replaces any stale supervisor registration and opens the installed copy from `~/Applications`.

## Further documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Agent integrations](docs/INTEGRATIONS.md)
- [Privacy](docs/PRIVACY.md)
- [Validation](docs/VALIDATION.md)
- [Known limitations](docs/KNOWN_LIMITATIONS.md)
