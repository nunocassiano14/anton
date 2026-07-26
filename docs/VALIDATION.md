# Validation

## Automated suite

`swift run anton-self-test` is the authoritative runner on machines that have only Apple Command Line Tools. It executes real assertions and returns a non-zero status on failure.

Current coverage:

- Main session lifecycle and visual callout signal on main Stop
- Concurrent callout FIFO, urgent priority and duplicate coalescing
- Codex turn identity across fast start/completion boundaries
- Duplicate Terminal/iTerm TTY inventory reconciliation
- Direct and Node-wrapped CLI process classification
- Multiline Markdown response preview preservation
- Subagent main-turn completion suppression
- Structured question decoding
- Sparse terminal identity merging
- Prompt and transcript-field exclusion
- Claude Stop response recovery without forwarding its transcript path
- Claude latest-turn completion detection from local transcript boundaries
- Current approval context retention
- Claude approval response schema
- Claude question answer injection
- Codex question feedback schema
- Codex neutral Stop JSON
- Exact Terminal and iTerm route resolution
- Request-ID isolation for approvals and questions
- Settings persistence
- Concrete Claude and Codex adapter identity
- Fake Claude/Codex adapter isolation
- Fake terminal reply isolation
- Claude configuration preservation, idempotency, backup, and removal
- Codex hook creation and clean removal
- Authenticated Unix-socket round trip and `0600` permissions
- Invalid-token rejection before the application handler
- Duplicate startup rejection without unlinking the supervised IPC socket

The same core behavior is represented in Swift Testing files under `Tests/GilfoyleCoreTests`.

## Command Line Tools caveat on the target Mac

The installed Swift 6.3.2 Command Line Tools contain `Testing.framework` but omit the normal test-discovery/runtime wiring. The standard test bundle compiles after adding the framework search path, yet `swift test` discovers zero cases. A deliberately failing discovery sentinel confirmed the defect and was removed.

`Scripts/test.sh` therefore always executes `anton-self-test`. When `/Applications/Xcode.app` exists, it also runs the standard Swift Testing suite with that complete developer toolchain.

## Manual real-agent checklist

These checks require the built app, macOS permission dialogs, and interactive local agents:

- [x] Launch the real signed `Anton.app`
- [x] Inspect first-run onboarding
- [x] Inspect compact primary-display notch surface
- [x] Inspect expanded empty board
- [x] Inspect Settings and menu-bar states
- [ ] Grant Automation for Terminal and iTerm
- [x] Install Claude and Codex hooks
- [ ] Trust Codex hooks with `/hooks`
- [x] Start Claude Code in Terminal.app
- [x] Start Codex in iTerm2
- [x] Confirm both appear automatically
- [x] Confirm Working and Finished states
- [x] Confirm one visual callout per main turn
- [x] Confirm concurrent responses queue without replacing the visible callout
- [ ] Focus the exact original tab for both agents
- [ ] Send a reply to each exact session
- [ ] Verify Enter, Shift+Enter, and Escape
- [ ] Allow and deny one real approval
- [ ] Answer one real structured question
- [ ] Dictate into the native reply field with Wispr Flow
- [x] Enable and verify the per-user launchd supervisor
- [x] Observe that no TCP listener or runtime network request is created
- [ ] Remove both integrations and compare preserved configuration

Do not mark a release complete until this checklist is performed on the target Mac.

## Target-Mac run, 2026-07-25

The ad-hoc signed app was installed at `~/Applications/Anton.app`. A real Claude Code print-mode session completed successfully in Terminal on `/dev/ttys004`, appeared automatically, and produced the camera-safe visual callout. A real Codex exec session started in iTerm on `/dev/ttys005`; its installed hooks emitted successful `SessionStart` and `UserPromptSubmit` events before the workspace refused model execution because it had no remaining credits. The active Codex desktop session independently exercised Working, tool, Stop, and replacement-callout states.

The installed process held only the private Unix socket and no TCP or UDP listener. Both the token and socket were mode `0600`. The per-user launchd job was loaded and running from the installed application path.

Installing the final ad-hoc signature invalidated prior macOS Automation consent, as expected. That user-mediated permission, the refreshed Codex `/hooks` trust decision, exact-session focus/reply, real approval/question responses, and Wispr Flow dictation remain unchecked above.

## Stability audit, 2026-07-26

- Reproduced repeated `EXC_BREAKPOINT` crashes in `TerminalInventory.read()` caused by duplicate TTY dictionary keys.
- Replaced the uniqueness precondition with deterministic last-value merging.
- Profiled the installed process and cached PID/session metadata plus Terminal/iTerm inventory.
- Reduced idle rendering by pausing completed/idle glyphs and lowering decorative animation cadence.
- Ran the 30-case standalone suite and a production build without warnings.
- Captured compact, onboarding, callout, board, and Settings states from the installed binary.
- Completed a post-install soak with no new crash reports; CPU stayed near 4% with five live CLIs.
