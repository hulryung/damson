# Workbench tools

Tracked in #43–#49. These tools are available from **Tools**; the command palette
also exposes enabled menu commands and live panes across windows.

| Tool | Use |
| --- | --- |
| Command Palette | `⌘⇧P`, search by action, tab title or cwd, arrow keys and Return; Escape returns to the original window. The shortcut is remappable in Settings → Keys. |
| File actions | Right-click a path or file URI for Finder, Quick Look, editor, path/URI copy, or a new terminal in the containing folder. VS Code supports `file:line`; TextEdit is the fallback. |
| Command notifications | Enable **Notify When Long Commands Finish**. Commands lasting at least 10 seconds notify when their pane is not focused. Clicking a notification reveals its originating pane. Requires macOS notification permission. |
| Workspace presets | Save a named layout and reopen it in a new window. Saves folders, tab names/groups, splits and zoom; starts fresh shells. Existing sessions are preserved. Delete removes only the preset. |
| Agent Activity | Search explicit provider reports and Claude observations. Waiting reports sort first; Return reveals the exact pane. Refreshes every three seconds. Unreported supported launchers show unknown. |
| Project Summary | On-demand cwd, Git branch/changed-file count and TCP listeners owned by the pane's foreground process. Refresh checks the same folder. Local browser links are candidates; HTTP is not inferred from a port alone. |
| Quick Terminal | **Show/Hide Quick Terminal** reuses a dedicated terminal window. Enable the global `⌃⌘` + grave-accent shortcut separately. Registration failure leaves the setting disabled. |

## Shell command lifecycle

The generated zsh integration emits OSC 133 `C` before execution and `D;status`
after execution, then `A` for the prompt. The terminal records monotonic elapsed
time, output boundaries and optional exit status. A new prompt without an end
marker cancels the incomplete record, never inventing success. Duplicate end
markers do not produce duplicate completion events. Other shells can provide the
same protocol; automatic injection remains zsh-only.

## Provider-neutral agent reports

A CLI or its hook can write a report to its own terminal:

```sh
printf '\033]777;damson;agent;waiting\007'
```

States: `running`, `waiting`, `completed`, `failed`, `unknown`. `clear` removes the
report. The report is scoped to the emitting PTY and includes a receipt timestamp
in the activity panel. It takes precedence over a Claude observation for that
pane. Reports also appear in `pane-info` and `watch-agents`. Existing Claude
statuses remain unchanged when no explicit report exists.

Only `running` and `waiting` map onto existing ambient/attention badges. The
activity panel and protocol preserve the other explicit states. A provider's
`completed` report is not proof that external validation passed, and does not
advance managed workflows. Inactivity is never interpreted as completion.

Adapters must emit new states as their tool progresses and `clear` when they no
longer own the pane. Other providers are not automatically instrumented; a
launcher without reports remains unknown. Remote sessions must arrange for
reports to reach the local terminal (for example tmux passthrough).

## Storage and limits

Workspace presets use a versioned JSON file at
`~/Library/Application Support/Damson/workspaces.json`, written atomically. They
exclude commands, shell history, scrollback and PTY identities, including when an
edited file supplies them. Missing folders follow the existing session-restoration
fallback. Presets use current appearance/shell settings with saved per-pane zoom;
they do not snapshot a separate configuration profile.

Project queries run off the main thread with a five-second process timeout and
a two-megabyte output cap. Listener discovery is restricted to the known
foreground PID, so services in other process groups are not listed. These are
local tools: remote file URI actions are disabled, and remote Git/SFTP inspection
is not provided.

## Verification (2026-10-27)

- `swift build --product damson`: passed.
- Targeted terminal/agent/control regression selection: 165 tests, zero failures,
  one existing environment-dependent skip.
- `python3 scripts/test-shell-integration.py`: real interactive zsh emitted start
  markers and exit codes 1/0 without sourcing user configuration.
- `python3 scripts/test-workbench-live.py --pid PID --runtime DIR`: all six
  provider report transitions passed against an isolated current-build app, with
  exact-pane reveal and cleanup.
- Native GUI: command palette → split; save named workspace → reopen in a new
  window with the original preserved; Unicode/space filename → Quick Look with
  correct contents; explicit waiting report → activity list; project fixture →
  branch `audit`, exactly two changed files, correct owned TCP listener; dedicated
  quick-terminal window hide/show without closing it.

Remaining release checks: notification banner delivery and click routing with
macOS authorization, physical global-hotkey delivery while another app is active,
and editor-specific line navigation. Synthetic per-app keyboard input does not
establish global-hotkey delivery. No production install or release was performed.
