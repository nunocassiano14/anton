# Agent integrations

## Claude Code

Anton patches `~/.claude/settings.json` and registers command hooks for:

- `SessionStart`
- `SessionEnd`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `PostToolUseFailure`
- `Stop`
- `StopFailure`
- `Notification`
- `Elicitation`

Every handler calls the bundled helper with `--agent claude`. Interactive events receive a 650-second hook timeout; normal lifecycle events use short timeouts.

Claude approval output uses `hookSpecificOutput.hookEventName = PermissionRequest` with an explicit `allow` or `deny` decision. Structured `AskUserQuestion` responses use a `PreToolUse` allow decision and inject the selected answers into `updatedInput`.

Reference: [Claude Code hooks](https://code.claude.com/docs/en/hooks).

## Codex CLI

Anton creates or patches `~/.codex/hooks.json` and registers:

- `SessionStart`
- `SessionEnd`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `Stop`

Every handler calls the bundled helper with `--agent codex`.

Codex requires review and trust for non-managed command hooks. After installation or after the helper path changes:

1. Start Codex.
2. Run `/hooks`.
3. Select the new or changed Anton hook definition.
4. Review its absolute command path.
5. Trust and enable it.

Approval output uses the official `PermissionRequest` allow/deny schema. Codex `Stop` emits neutral valid JSON. For `request_user_input`, Anton blocks that specific tool call and returns the selected answer as model-visible hook feedback; Codex then continues from that explicit response.

Reference: [Codex hooks](https://learn.chatgpt.com/docs/hooks).

## Backups

Before changing an existing file, Anton copies it to:

```text
~/Library/Application Support/Anton/Backups/<timestamp>/<agent>/
```

The timestamp includes milliseconds to avoid collisions. New configuration files do not need a pre-change backup because no previous state exists.

## Repair

Repair runs the same idempotent installer:

- Present Anton handlers remain unchanged.
- Missing event handlers are added.
- Unrelated hooks remain untouched.
- A backup is created only if a material edit will be written.

## Removal

Removal filters individual handlers by the `anton-hook` command marker. Matcher groups containing another handler are retained. Unknown top-level settings remain unchanged.

The Codex hook file is deleted only when no hooks and no unrelated top-level fields remain. Claude's settings file is never deleted.
