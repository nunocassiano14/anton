# Architecture

Anton is split into a dependency-free Swift core, a short-lived hook helper, and a native SwiftUI/AppKit menu-bar application.

```text
Claude Code / Codex
        │ official lifecycle hook, JSON on stdin
        ▼
 bundled anton-hook
        │ sanitized BridgeRequest + per-install token
        ▼
 private Unix socket (0600)
        │
        ├──► SessionReducer ──► in-memory SessionStore ──► notch/menu UI
        │
        └──► InteractionResponseBroker ◄── Allow / Deny / answer
                       │
                       ▼
             official hook JSON on stdout

Native reply editor ──► TerminalRouteResolver
                       ├── Terminal.app: exact TTY
                       └── iTerm2: unique session ID, then TTY fallback
```

## Targets

### `AntonCore`

The core target has no UI dependency and contains:

- Shared agent, session, terminal, question, and interaction models
- JSON decoding with a dynamic `JSONValue`
- Claude and Codex lifecycle adapter protocol and concrete adapters
- Minimal hook input sanitization
- Official hook-response rendering
- Deterministic session state reducer
- Exact terminal-route validation and normalization
- Request-ID interaction response broker
- Persisted preference repository
- Reversible configuration installer/remover
- Authenticated Unix-domain socket client and server

### `anton-hook`

The helper is invoked directly by official Claude Code and Codex command hooks. It:

1. Reads one hook event from standard input.
2. Selects the Claude or Codex lifecycle adapter from `--agent`.
3. Determines Terminal versus iTerm from environment metadata.
4. Walks the parent process chain to recover a TTY and the agent process ID.
5. Drops prompt and transcript fields before creating a `BridgeRequest`.
6. Loads the per-user IPC token.
7. sends one newline-delimited JSON request through the private Unix socket.
8. Waits for a response only when an approval or question is interactive.
9. Writes the event-specific official response schema to standard output.

If Anton is not running, the socket connection fails locally and the helper exits without changing the agent's normal behavior.

### `Anton`

The app uses:

- `NSPanel` for the non-activating notch surface
- SwiftUI for the panel, session cards, onboarding, and Settings
- `NSStatusItem` for the menu-bar interface
- `NSTextView` for the multiline reply editor
- Carbon hot keys for a configurable global shortcut
- Apple Events through `osascript` for exact Terminal/iTerm handoff
- `SMAppService` for Launch at Login
- `DispatchSourceProcess` to detect unexpected agent exit without polling

The panel is attached to the primary display only. It remains up to 520 points wide and at least 46 points high until the user clicks it or invokes the shortcut, leaving room for the physical camera and a concise state summary. A main-turn completion opens a visual callout whose height includes the display's real top safe area. The full session board expands to at most 580×620 points while respecting the visible screen frame. Centered content is placed below `NSScreen.safeAreaInsets.top`; counters and controls stay in the safe areas beside the physical camera. Passive boards and callouts never become the key window; only an explicit Reply action can move keyboard focus to Anton.

## Session identity

The stable application session key is:

```text
<agent kind>:<agent session id>
```

Terminal targeting is deliberately separate from that logical key:

- Terminal.app requires a non-empty `/dev/ttys…` value.
- iTerm2 prefers the UUID portion of `ITERM_SESSION_ID` and retains the TTY as a fallback.
- Unknown terminals or sessions without stable targeting metadata are rejected instead of sending to a guessed or frontmost tab.

Later sparse hook events merge with existing terminal context rather than erasing a previously discovered identifier.

## Agent event mapping

Both agent adapters reduce supported lifecycle events into the same state model:

| Event | Result |
| --- | --- |
| `SessionStart` | Idle / connected |
| `UserPromptSubmit` | Working |
| normal `PreToolUse` | Working with current activity |
| question `PreToolUse` | Has a question and blocks for an answer |
| `PermissionRequest` | Needs approval and blocks for Allow or Deny |
| `PostToolUse` / failure | Working / processing result |
| `Stop` | Finished, focused visual callout |
| `StopFailure` | Error |
| `SessionEnd` | Disconnected |

Subagent completion does not enter the main-turn finished path and does not open a callout. Codex `Stop` returns an empty JSON object, which is a neutral successful hook result. Claude question answers use `updatedInput.answers`. Codex currently receives a blocked `PreToolUse` result whose model-visible reason contains the explicit answer, because its request-input tool does not expose a separate direct-answer hook channel.

## Interaction safety

Every interactive hook invocation receives a unique `requestID`. `InteractionResponseBroker` stores its response closure under that ID. UI actions must resolve the exact ID before a response is written to the waiting helper.

Consequences:

- A response cannot fall through to the most recently focused terminal.
- A stale or duplicate click is rejected.
- Closing Anton cancels all waiting hooks.
- If the observed agent process exits, its pending interaction is cancelled and the session becomes disconnected.

Normal prompt replies use the stored terminal route and Apple Events. They do not use the hook response broker because they behave like explicit keyboard input in the original session.

## Local IPC

Paths are under `~/Library/Application Support/Anton/`:

- `bridge.sock`: Unix-domain stream socket, mode `0600`
- `ipc-token`: 256-bit random authentication token, mode `0600`

Each request includes protocol version 1 and the token. The server compares tokens in constant time and rejects mismatched protocol versions or tokens before the application handler sees the message. Messages are bounded to 256 KiB and newline-delimited. No TCP listener is created.

## Configuration edits

`IntegrationInstaller` reads JSON into a dictionary, inserts only missing event handlers, and writes sorted, pretty JSON atomically. It:

- Preserves unknown keys and unrelated hooks
- Avoids duplicate Anton handlers
- Retains existing file permissions
- Backs up every existing file before a material change
- Removes only handlers whose command contains the bundled `anton-hook` marker
- Deletes a Codex `hooks.json` only when Anton created the effective contents and nothing unrelated remains

The app never edits Codex's `notify` setting or replaces a complete Claude/Codex configuration.

## Persistence and privacy boundary

Persistent:

- Global shortcut
- Onboarding completion
- Launch-at-login preference
- IPC authentication token
- Recoverable integration backups

Memory only:

- Session board
- Current activity and last action
- Current response preview
- Current approval/question
- Pending reply text

Explicitly discarded:

- User prompt content from lifecycle events
- Transcript paths
- Tool inputs not required for the current approval or question
