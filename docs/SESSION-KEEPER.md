# Session keeper — restart survival

`damson.keepSessionsOnRestart` (Settings → Terminal → Sessions, off by default) lets tabs,
panes, and the programs running in them survive an app restart: a Sparkle update install,
the App menu's "Restart Damson", or "Keep Sessions & Quit" in the quit dialog. Plain
"Quit" still terminates everything.

## Why a separate process

A terminal's children die with it because closing the LAST descriptor of a PTY master
delivers SIGHUP to the child's session. Survival therefore needs the master fd to stay
open somewhere while the app is gone — that somewhere is `damson-keeper`, a tiny
Foundation-only daemon (`Sources/damson-keeper`). The app hands each surviving session's
master over a socketpair via SCM_RIGHTS (`Sources/CFDPass` — the CMSG macros don't import
into Swift), the children reparent to launchd untouched, and the next app instance claims
the fds back over `$TMPDIR/damson-<uid>/keeper-<generation>.sock`.

The keeper also DRAINS every held master into an append-only buffer (cap 4MB/session,
then it stops reading and lets the child block at the ~1KB kernel tty queue — bounded
memory, no loss). The buffer is replayed into the adopting parser, so output printed
during the restart lands in scrollback like any other bytes.

## The handoff (quit side)

`applicationWillTerminate` (main.swift), when the feature is on and the termination is a
keep-type one:

1. Per session: capture `stateRestorationPreamble()` (the escape bytes that recreate the
   tracked modes — mouse reporting, bracketed paste, alt screen, title…), then
   `releasePTYForHandoff()` → `PTYHost.releaseOwnership()` stops the poll-based read loop
   via a wake pipe, captures the undelivered byte tail, snapshots cwd + the child's
   proc start time, and clears ownership so `terminate()`/`deinit` no-op.
2. `SessionHandoff.handOffAll` spawns the keeper (a COPY of the binary in the runtime dir,
   `posix_spawn` with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`, our environment,
   socketpair on fd 3) and sends `{hold header}\n` + 1 byte + fd per session, lockstep.
3. `RestorableState` is saved with `handoffGeneration` and per-leaf `sessionID`/`preamble`;
   handed-off leaves always get their scrollback written (alt-screen panes without the
   visible frame — the redraw repaints it).

Sessions that can't hand off (tmux panes, the `tmux -CC` control client) terminate as
always. If the keeper can't be spawned, the released fds are closed — children get
SIGHUP, i.e. exactly a normal quit.

## The claim (launch side)

`applicationDidFinishLaunching` claims before restoring: hello{generation} → inventory →
per-uuid claim (grant header + buffer, then the fd) → ack → end. The keeper closes its
fd copy at ack (so the app's close is once again the LAST close), closes whatever wasn't
claimed, and exits. Unclaimed for 15 minutes, or SIGTERM (logout): close everything —
children get standard logout HUP — and exit.

Each adopted leaf builds `PTYHost.adopt(fd:pid:startSec:startUsec:replay:)` +
`DamsonSession(config:restoredScrollback:backend:)`. Replay = preamble + tail + keeper
buffer, delivered through `onData` before the read loop starts, so bytes parse in exact
order. Adopted exit detection is EOF/POLLHUP (the child was reaped by launchd; waitpid
is impossible) and any signal is gated on a pid + start-time identity match — a recycled
pid is never signaled. Termination closes the fd first (SIGHUP), signals only escalate.

The first resize after adoption forces a real SIGWINCH: same-size resizes generate no
signal, and a back-to-back ±1 column pair coalesces into "no change" for the TUI — so the
pty parks one column short and restores 300ms later (the tmux attach dance), guaranteeing
a full repaint of alt-screen programs.

## Failure modes

- Keeper dies → kernel closes held fds → children HUP → normal-quit semantics.
- Child dies while held → EOF marks it dead; its leaf falls back to a fresh shell with
  restored scrollback (and the "session restored" separator).
- Generation mismatch (stale keeper, another instance) → claim refused → fresh-spawn path.
- Crash (no handoff ran) → nothing held → plain restore, as before this feature.

## Limits

- Compact (tab-bar) mode only — same scope as layout restore.
- Terminal modes damson doesn't track (DECCKM etc.) aren't restored; scroll region and
  saved cursor are deliberately left to the post-adopt WINCH repaint.
- The real exit status of an adopted child is unobtainable (reported as 0).
