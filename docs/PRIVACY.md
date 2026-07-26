# Privacy

Anton is deliberately local-only.

It contains:

- No analytics SDK
- No telemetry pipeline
- No account or identity system
- No payment or subscription code
- No cloud backend
- No HTTP client or runtime network request
- No transcript upload
- No persistent session or prompt history

## Data processed

The app receives only the current structured lifecycle event needed to render a live session:

- Agent and agent session identifier
- Working directory and project name
- Model, when provided
- State and current tool name
- Terminal environment identifiers and agent process ID
- The latest assistant preview on a main Stop event
- The current tool input only for an approval or structured question

The helper excludes the prompt and transcript path even when the agent includes them on standard input. Normal tool inputs are excluded because the live board does not need them.

For already-open Codex sessions, Anton also reads a bounded tail of Codex's
local rollout file. It derives a short live label such as `Searching the web`,
`Running tests`, or `Reading NotchRootView.swift`. Raw commands, tool output,
prompts, and response text are not retained as activity metadata and never
leave the Mac.

## Data stored

The session board and current interactions stay in memory and disappear when Anton quits.

The following local operational data persists:

- Preferences in `UserDefaults`
- A random IPC token
- Timestamped backups of configuration files Anton modifies

No prompt or reply is written by Anton. A reply is held only long enough to send it through the exact terminal automation call. Claude Code and Codex remain responsible for their own conversation history.

## Local communication

The helper connects to a Unix-domain socket with mode `0600`. Requests require a 256-bit token stored in a separate `0600` file. Anton opens no TCP port.

Terminal replies use local Apple Events only after an explicit user submission. Approval and question responses travel back through the blocked local hook process.

## Configuration access

Anton reads and minimally patches:

- `~/.claude/settings.json`
- `~/.codex/hooks.json`

It does not read transcript files referenced by hook events. Existing configuration is backed up before material changes, and removal is selective.
