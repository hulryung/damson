# Workbench tools

Tracked in #43–#49. These tools are available from **Tools**; the command palette
also exposes the menu's commands and live panes across windows.

| Tool | Use |
| --- | --- |
| Command Palette | `⌘⇧P`, search by action, tab title or cwd, arrow keys and Return; Escape (or the close button) returns to the original window. Title matches rank above menu-path/cwd matches. Each command shows its current shortcut (remaps included; arrows as `⌥⌘←`). Commands unavailable in the original window are shown greyed and do nothing on Return. The shortcut is remappable in Settings → Keys. |
| File actions | Right-click a path or file URI for Finder, Quick Look, editor, path/URI copy, or a new terminal in the containing folder. Relative paths resolve against the pane's cwd; a `:line[:col]` suffix (also after a `file://` URI) is passed on. **Open in Editor** uses the file's default app when it is a known editor, else the first installed of VS Code, Cursor, Zed, Sublime Text, Windsurf, VSCodium, VS Code Insiders, a JetBrains IDE; Xcode only as the default app; TextEdit (no line) last. It is enabled only for text-like files. Plain (non-URI) paths stop at whitespace, so names with spaces need a `file://` URI or OSC 8 link. |
| Command notifications | Enable **Notify When Long Commands Finish** (Tools menu, or Settings → Terminal → Command Notifications, which also sets the minimum duration, default 10 s). A command notifies unless its pane is focused in the frontmost app. Clicking a notification reveals its originating pane by pane id; if the pane has closed it only brings Damson forward. Requires macOS notification permission. |
| Workspace presets | Save a named layout and reopen it in a new window. Saves folders, tab names/groups, splits and zoom; starts fresh shells. Existing sessions are preserved. Saving under an existing name (case-insensitive) asks before replacing it. Delete removes only the preset. In Standard mode the window's native tabs are saved together. |
| Agent Activity | Search explicit provider reports and Claude observations. Each row shows state, source (explicit report with receipt time, or Claude observation) and cwd. Waiting panes sort first, then failed reports, then the rest by title; Return reveals the exact pane. Refreshes every three seconds. Unreported supported launchers show unknown. |
| Project Summary | On-demand cwd, Git branch (or detached commit)/changed-file count and TCP listeners owned by the pane's foreground job. Refresh checks the same folder and re-reads the pane's current foreground job. Local browser links are candidates; HTTP is not inferred from a port alone. |
| Quick Terminal | **Show/Hide Quick Terminal** reuses a dedicated terminal window. Enable the global shortcut in Settings → Window → Quick Terminal (or Tools); it defaults to `⌃⌘` + grave accent and can be re-recorded there. Hiding orders out only that window and returns focus to the app it was summoned from. The window survives a restart as the quick terminal (hidden if it was hidden), and a hidden quick terminal keeps the app running when the last visible window closes. |

## Shell command lifecycle

The generated zsh integration emits OSC 133 `C` before execution and `D;status`
after execution, then `A` for the prompt. The terminal records monotonic elapsed
time, output boundaries and optional exit status. A new prompt without an end
marker cancels the incomplete record, never inventing success. Duplicate end
markers do not produce duplicate completion events. Other shells can provide the
same protocol; automatic injection remains zsh-only. bash (macOS ships 3.2, without
`PS0`) and fish would need their own hooks — a `DEBUG` trap/`PROMPT_COMMAND` pair and
a `fish_preexec`/`fish_postexec` vendor config — and are not provided yet.

## Provider-neutral agent reports

A CLI or its hook can write a report to its own terminal:

```sh
printf '\033]777;damson;agent;waiting\007'      # BEL or ST (ESC \\) terminated
```

The grammar is exactly `OSC 777 ; damson ; agent ; <state> BEL|ST`; anything else is
ignored, and an unrecognised state leaves the previous report in place. A hook whose
stdout is captured by the agent (Claude Code's hooks are) must write to `/dev/tty`
instead. Inside tmux, wrap it for passthrough
(`set -g allow-passthrough on`):

```sh
printf '\033Ptmux;\033\033]777;damson;agent;running\007\033\\' > /dev/tty
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
longer own the pane. A report belongs to the process group that held the terminal's
foreground when it arrived (agent hooks run inside the agent's group). When that group
no longer exists the report is dropped, so an agent that exits or crashes without
`clear` reads as unreported rather than as running forever. Consequently a report sent
by a short-lived external command typed at the prompt expires when that command exits;
send it from the agent's own process, its hooks, or a shell builtin (`printf` in a
wrapper function belongs to the shell and lasts until `clear` or the shell exits).
Panes without a tty to ask (tmux `-CC`) keep reports until `clear`. Other providers
are not automatically instrumented; a launcher without reports remains unknown. Remote sessions must arrange for
reports to reach the local terminal (for example tmux passthrough).

## Storage and limits

Workspace presets use a versioned JSON file at
`~/Library/Application Support/Damson/workspaces.json`, written atomically. They
exclude commands, shell history, scrollback and PTY identities, including when an
edited file supplies them. A file written by a newer format version, or one that
cannot be read, is reported and never overwritten. Missing folders follow the existing
session-restoration fallback (nearest existing parent, else home), and opening says which. Presets use current appearance/shell settings with saved per-pane zoom;
they do not snapshot a separate configuration profile.

The quick-terminal shortcut is a Carbon hotkey: only the exact chord is delivered, and
a chord without ⌘ or ⌃ is refused so it cannot swallow typing. A chord already used by
one of Damson's own shortcuts is refused in the recorder. macOS refuses a chord only when
it is already registered by the system or this app — another app's ordinary registration
of the same chord is not reported, so a silent clash is resolved by choosing a different
chord. A failed registration is reported and rolled back to the previous chord, or the
setting is turned off.

Project queries run off the main thread with a five-second process timeout
(SIGTERM, then SIGKILL; the panel does not wait for a pipe a grandchild still
holds) and a two-megabyte output cap. Timeouts, oversized status output ("more than
N"), missing folders, a missing Git (`/usr/bin/git` is used only when the developer
tools are installed, so the install dialog never appears; Homebrew git is the
fallback), a Git directory without a work tree, and other Git errors are each
reported as such, never as "not a repository". Git's stderr is read separately and
never counted as a status record. Listener discovery uses `lsof -g` on the pane's
foreground process group, so a server started by `npm run dev` (owned by a child of
the group leader) is found, while services in other process groups (background jobs,
other panes) are not listed. Each listener names its owning command and pid.
These are local tools: remote file URI actions are disabled, and remote Git/SFTP inspection
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
