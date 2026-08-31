---
name: damson-verify
description: >-
  Hand-verify a change to the damson terminal without producing a convincing wrong answer.
  Use when working in the damson repo and about to test behaviour by running the app —
  "test this in damson", "make a dev build", "does the restore work", "reproduce the
  rendering glitch", "check the keeper", "did the session survive a restart", "screenshot the
  tab bar" — or when a hand-test result looks too clean to believe.
---

# Verifying damson by hand

`swift test` covers the model. This is about the other half: running the app and believing
what you see. Every trap below has produced a confident, wrong conclusion in this repo.

## Build and launch a dev instance

`./scripts/run-dev.sh` builds `dist/Damson.app` and launches it with `open -n`, separate from
`/Applications`. Address it by pid: `.build/debug/damson-cli --list-instances`.

**Strip the session env when agents are involved.** A dev app launched from inside a Claude
Code session inherits `CLAUDE_CODE_CHILD_SESSION`, which stops any `claude` in a pane from
writing its session record — so agent badges and `watch-agents` silently produce nothing:

```sh
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID open -n dist/Damson.app
```

**PATH inside the .app is minimal.** LaunchServices does not give it your shell's PATH, so
`spawn -- claude` fails and the pane closes instantly, looking like a spawn bug. Use an
absolute path (`/opt/homebrew/bin/claude`).

## Quitting and restarting

**A scripted quit silently does not quit.** `applicationShouldTerminate` runs a modal for any
quit that is not a restart, so `Cmd+Q` leaves the app alive with a dialog up. If you then
kill processes assuming it is gone, you are killing panes of a **live** app.

Use the menu item, targeted by unix id so it cannot hit the user's own damson:

```sh
osascript -e 'tell application "System Events" to tell (first process whose unix id is <PID>) \
  to click menu item "Restart Damson" of menu 1 of menu bar item "Damson" of menu bar 1'
```

**Never send a blind `Cmd+Q` keystroke.** The user may be running this very session inside
another damson window.

**`pkill -f damson-keeper` never matches.** The app runs a per-generation copy named
`keeper-bin-<generation>`. Every run that looked like a cold start was really the adopt path.

**Session handoff is off by default.** `damson.keepSessionsOnRestart` is a setting; unset, a
restart takes the cold path and every pane comes back with a new pid. That is not a keeper
regression — check the setting before concluding one.

**Adopted children are not damson's children.** They reparent to launchd, so
`pgrep -P <damson>` will not list them. Use `damson-cli agents`, which reports the pid damson
actually sees.

## Rendering bugs

Split the question before debugging: **`damson-cli dump-grid` shows the parser's answer, a
screenshot shows the renderer's.** A clean grid with a broken screen is a renderer bug; a
broken grid is a parser bug. Debugging the wrong half costs hours.

For a reproducible sequence, capture the bytes rather than describing the picture:

```sh
DAMSON_DUMP_OUTPUT=/tmp/dump open -n dist/Damson.app
```

Then replay and bisect. A tokeniser that only understands CSI/OSC will print `ESC M` as text
`M` — the RI bug was nearly missed that way, so decode ESC sequences too.

**The dump records every output byte of a pane.** Do not capture a window where passwords or
tokens are typed, and delete the directory afterwards.

## Screenshots

- A sleeping display captures **solid black**. `caffeinate -u -t 3` first.
- `CGWindowBounds` **includes the shadow**, and the shadow changes with focus — the numbers
  move when a window becomes key. Capture by window id (`screencapture -l <id>`) rather than
  computing a region from those bounds.
- `sips -c H W` crops from the **centre**, not the top.

## Before believing a hand-test

Ask what would have looked identical if the thing under test never ran. A fixture that exits
immediately (`zsh -i -c "<some prose>"` runs the prose as a command) makes a working feature
look broken, and a cold-restart path that re-runs argv makes a broken keeper look fine.
