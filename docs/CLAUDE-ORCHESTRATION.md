# Claude Code orchestration

damson can open, address and observe panes running Anthropic's `claude` CLI. This is what
that means, why it stops where it stops, and which of the obvious next moves are traps.

The scope is deliberately narrow: **damson observes and addresses agents; it does not
schedule them.** No task board, no concurrency cap, no worktree lifecycle. Those belong to a
cockpit — [damson-ide](https://github.com/hulryung/damson-ide), which was split out of this
repo in `e4d14f9` — and `claude -w` already owns worktrees. The test for whether this
boundary still holds: **deleting `Sources/DamsonAgents` must leave damson compiling, with
`spawn-pane` and pane ids still useful for any argv.**

---

## 1. The mechanism

Two facts joined, not an inference:

1. A pane can name the process group owning its tty — `DamsonSession.foregroundProcessID`,
   ultimately `tcgetpgrp(primaryFD)`. Only the process holding the PTY **master** can ask
   this, which is why it can't be obtained from outside damson.
2. Claude Code publishes one record per live session at
   `~/.claude/sessions/<pid>.json`, keyed by that same pid.

So "is this pane an agent, and how is it doing" is a dictionary lookup.

```
pane ──tcgetpgrp──► pid ──►  ~/.claude/sessions/<pid>.json  ──► status
```

A shell puts each foreground job in its own process group led by that process, so the pgid
IS the pid of the program in the pane. Verified both ways: a pane damson spawned directly on
`claude` (claude is the child), and a user typing `claude` into an interactive shell (claude
is a job of that shell).

### Status vocabulary

`busy` · `shell` · `idle` · `waiting`, plus an optional free-form `waitingFor` string.
Read out of Claude Code 2.1.228 itself, not from documentation.

`AgentBadge` is the **only** place this vocabulary is written down, and the mapping is
closed: an unrecognized status yields **no badge**. That direction is deliberate — a stale
"idle" pill on an agent that is actually blocked is worse than no pill, because the user
acts on it. A future release that adds a state degrades to quiet, never to wrong.

Only `waiting` reaches the tab title. It is the one state that will not resolve without the
user; if more escalated, the badges would become noise people learn to ignore — and then
miss the one that mattered.

### Why poll instead of watching the directory

The session records are rewritten **in place**, not renamed into position. A `DispatchSource`
vnode source on the directory fires on add/remove/rename only, so every badge would freeze
at whatever state its session had when it started. A `stat`-and-reread sweep over a handful
of small files is cheap and, more importantly, correct.

### Hot-path rule

The sweep runs on a 3s timer and nowhere else. It must never be wired to
`DamsonSession.onOutput`, `outputEvents`, or a render callback. A pane under an output flood
already spends its main-thread budget parsing; this feature is not worth a byte of it. Cost
per non-agent pane per tick is one ioctl and one dictionary miss.

---

## 2. Addressing panes

Panes used to be reachable only as "the active one" or by an index into `tabs` — which
splitting, closing, reordering and cross-window drags all renumber. `PaneRegistry` gives each
pane a UUID, minted on first use and keyed on session identity, so it survives every
structural change including a move between windows.

**The trap that class is written around:** the forward map is keyed on `ObjectIdentifier`,
which is the object's ADDRESS, and a deallocated session's address is reused by a later
allocation. A lookup that trusts a hit will eventually hand a new pane a dead pane's id, and
a driver addressing "pane X" would silently talk to the wrong terminal. `id(for:)` therefore
confirms the entry still points back at the same object and mints fresh otherwise. Sweeping
cannot cover this — the collision exists from the instant the address is reused.

### Wire surface

`DamsonControl` is a public library product that damson-ide links, so orchestration was added
as **new** command kinds — `spawn-pane`, `list-agents`, `pane-info`, `watch-agents` — plus an optional
`"pane"` key on the envelope. Nothing existing was widened: adding an associated value to a
case is source-breaking at every construction site. `PaneInfo`/`ControlResponse` only gained
defaulted optionals, encoded with `encodeIfPresent`, so an ordinary pane's row is still the
original four keys and `ok()` is still `{"ok":true}`. A payload with no `"pane"` key decodes
to `.active` — what every client meant before the key existed.

```
damson-cli spawn [--split-h|--split-v] [--cwd P] [--key K] [--title T] [--group G] -- argv...
damson-cli agents
damson-cli pane-info --pane <id>
damson-cli --pane <id> send-text 'hello'
damson-cli --pane <id> set-title 'review-api'
damson-cli --pane <id> dump-grid
damson-cli watch-agents
damson-cli group list|close <name>|collapse <name>|expand <name>|rename <name> <new>
```

**Every pane-addressed command honors `--pane`**: `send-text`, `send-key`, `dump-grid`,
`zoom`, `resize-pane`, `focus-pane`, `close-pane` and `pane-info` all act on the named pane —
wherever it lives: the current tab, another tab, another window. The named pane substitutes
for "the active pane" in the command's meaning, so `resize-pane` nudges the divider governing
*that* pane and `focus-pane` moves focus relative to *it*. Addressing a pane does not focus
it: `send-text`/`dump-grid` against a background agent leave the user's focus alone.

A target that resolves to no pane is a **typed error** (`not a pane id: …` for a malformed
id, `no such pane: …` for a closed one) — never a fallback to the active pane. A driver that
addressed "pane X" must be told X is gone, not have its bytes land in whatever pane happens
to be focused.

**`--key` is an idempotency token, and it is not belt-and-braces.** `bindControlSocket`'s
handler hops to the main actor and waits 2s, then reports a timeout to the client *while the
queued work still runs to completion*. A spawn that overruns — easy behind a tab-creation
animation — answers "failed" for a pane that did open, and a client that retries would mint a
second agent. With a key, the retry is answered with the first pane's id.

### Waiting instead of polling

`watch-agents` is the one command that is not request/response: it keeps its connection open
and writes one NDJSON line per change until the client disconnects.

```json
{"event":"appeared","pane":"4E76A4A5-…","pid":16962,"status":"idle","cwd":"/private/tmp"}
{"event":"changed","pane":"4E76A4A5-…","previousStatus":"idle","status":"busy","cwd":"/private/tmp"}
{"event":"vanished","pane":"4E76A4A5-…","pid":16962,"previousStatus":"idle"}
```

A subscriber receives a snapshot of what is already running before any live change, so a
coordinator connecting mid-run starts from the present rather than from whatever happens
next. The stream exists because polling `list-agents` is correct but both wasteful and late:
it asks far more often than anything changes and still learns about a blocked agent up to a
sweep after it blocked — and `waiting` is precisely the state a human is being held up by.

Three properties a driver can rely on:

- **Edge-triggered.** An unchanged sweep emits nothing, so an idle machine produces no
  traffic and an inbox measures activity rather than elapsed time.
- **`waitingFor` is part of the state.** An agent moving from one question to another is
  `waiting` both times; the thing it is blocked on changed, so the change is reported.
- **A new process in an old pane is `vanished` + `appeared`, never `changed`.** Reporting a
  different pid as a status change would let a driver carry conclusions about one
  conversation into an unrelated one.

A `heartbeat` line every 20s keeps the connection honest: writes are the only liveness signal
available, so a client that went away is discovered by the write failing rather than leaving
a server thread parked for the life of the app. Subscribers have bounded per-connection
mailboxes — a reader that stops reading is dropped rather than allowed to grow damson's
memory on its behalf.

**This is the substrate, not a scheduler.** damson reports what changed; deciding what to do
about it — dispatching the next task, holding a gate, escalating — stays in the cockpit. See
the boundary test at the top of this document.

> Serving a subscription required making the control socket concurrent: `handleConnection`
> used to run inline in the accept loop, which was harmless while every exchange was one line
> in and one line out, and would have wedged every other client for a watcher's lifetime.
> One thread per connection, because a connection that blocks indefinitely would occupy a
> pool worker indefinitely.

### Naming the tabs

`spawn` with no `--split-*` opens a **new tab**, so the natural shape for a coordinator is
one tab per task. That only helps a human if the tabs are distinguishable, and by default
they are not: the tab shows the program's own title, so five `claude` panes are five
identical tabs.

`--title` (at spawn) and `set-title` (any time, on any pane, by id) write the tab label.
Empty text clears it and hands the tab back to the program.

```sh
id=$(damson-cli spawn --key review-api --title review-api --cwd "$wt" -- claude \
       | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
damson-cli --pane "$id" set-title 'review-api ✱ blocked'   # e.g. on a `waiting` event
```

This deliberately writes the **same slot as a double-click rename**, which buys two
properties that a separate coordinator-only field would not have:

- **It beats the program.** A stock shell rewrites the title on every prompt via OSC 0/2,
  so a label that merely won the race at spawn time would be gone by the first prompt —
  briefly right, then quietly wrong, which is worse than no label.
- **It survives a restart.** Labels ride in `RestorableWindow.tabTitles`, so an agent tab
  that rides a keeper handoff keeps the name its coordinator gave it.

`agents` and `pane-info` report `title` as **what the user actually reads** — the label if
one is set, the program's title otherwise. That is the field a coordinator joins its task
list against, so reporting the raw OSC title there would hide the label it just set.

### Grouping a run

`--group` puts the new tab in a named group, creating it if this window has none by that
name. That is the same idempotency `--key` gives the spawn itself, so a coordinator looping
over tasks never has to ask whether the group exists first.

```sh
for t in review-api fix-parser write-docs; do
  damson-cli spawn --key "$t" --title "$t" --group run-7 --cwd "$wt" -- claude "$prompt"
done
damson-cli group close run-7      # when the run is over
```

Groups are addressed **by name**: a coordinator names a run and never sees the UUID damson
keys groups on internally. Names are not unique, so a command naming a group acts on the
first one on screen — the only answer a user could predict.

A group's tabs are kept **contiguous**, so a tab joining late is relocated next to the
others rather than left where it was opened. `agents` and `pane-info` report `group`,
which is what a coordinator joins its task list against.

**`group close` is destructive** — several tabs and the programs inside them. A name that
matches nothing is a typed error and a non-zero exit, never a quiet success: a coordinator
that mistyped a run name must not be told the run was cleaned up.

### Splitting changes the active pane

A split makes the NEW pane active, so a subsequent `send-text` goes there, not to the agent.
Scripts should address panes by id rather than relying on focus. This is the whole reason the
`"pane"` key exists.

---

## 3. Restart survival

This is what damson has that a fresh app or damson-ide cannot: `damson-keeper` holds each
PTY master while the app is gone, so children never receive SIGHUP.
`SessionHandoff.handOffAll` **inspects nothing about the child**, so a pane running `claude`
rides an update with the same pid, the same conversation and the same context window. The
badge's pid join therefore re-establishes itself for free.

`SessionRestore` additionally saves `paneID` and `argv` on the existing `.leaf` case:

- **`paneID`** — only for a pane that already has one, so panes nobody addressed don't get
  ids minted at quit. Re-adopted on restore, so an external driver's binding survives.
- **`argv`** — only when it differs from the configured shell. On the cold path (no keeper
  answered, or the child died while held) the pane re-runs it instead of coming back as a
  login shell with the work gone.

Both are optional and both went on the **existing** case, never a new one: `load()` is a
single `try?` over the whole state, so a file carrying an unknown case would lose EVERY
window's layout on a downgrade. Verified in both directions — old data decodes with the new
fields nil, and a build compiled without them still reads new data intact.

### Why a Claude pane does NOT resume its conversation

`restartArgv` strips `--session-id` / `--resume` before re-running. That retreat is measured:

| attempt | result |
|---|---|
| `claude --resume <id>`, no transcript | `No conversation found` → **exits** |
| `claude --resume <id>`, real transcript | `No deferred tool marker found in the resumed session…` → **exits** |
| re-run `--session-id <id>` | an id whose conversation exists is a conflict |

A process that exits on startup **closes its pane**, so the user ends up with nothing where a
working terminal used to be — strictly worse than the login shell this set out to replace. So
the pane restarts clean, keeps its damson pane id and its label, and the conversation is one
`/resume` away, chosen by a human who can see whether it worked.

---

## 4. Verifying this by hand

Two traps make scripted verification produce convincing wrong answers. Both cost hours.

**The quit dialog.** `applicationShouldTerminate` runs a modal for any quit that is not a
restart (`if updateRelaunchPending || restartRequested { return .terminateNow }`). A scripted
"Quit and Keep Windows" therefore *silently does not quit* — `runModal()` just sits there. If
you then kill processes assuming the app is gone, you are killing panes of a **live** app.
Use "Restart Damson" (no dialog), or click the alert button:

```bash
osascript -e 'tell application "System Events" to tell (first process whose unix id is <PID>)
  to click button "Keep Sessions & Quit" of window 1'
```

**The keeper's process name.** The app runs a per-generation COPY named
`keeper-bin-<generation>` (`SessionHandoff.swift`), so `pkill -f damson-keeper` never matches
it. Every run that looked like a cold start was really the ordinary adopt path. Kill
`keeper-bin-` instead, and confirm against `$TMPDIR/damson-<uid>/keeper-<gen>.log`, which
records `hold` / `claimed` / `loop ended:` explicitly.

**Adopted children are not damson's children.** They reparent to launchd, so
`pgrep -P <damson>` will not list them. Use `damson-cli agents`, which reports the pid damson
actually sees.

**Launching a dev build from inside a Claude Code session** inherits
`CLAUDE_CODE_CHILD_SESSION`, which stops any `claude` in a pane from writing its session
record — so badges silently never appear. Strip it:

```bash
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID open -n dist/Damson.app
```

---

## 5. Do not build

Each of these looks like the obvious next step and is a trap.

**A scheduler that dequeues on `status: "idle"`.** `idle` conflates *task finished*, *asked a
clarifying question and is waiting on you*, and *spawned but never prompted* — live
mid-conversation sessions read as `idle`. A FIFO with a concurrency cap would start task 4
while agent 1 is blocked on "which auth flow did you mean?". A real queue needs headless
`-p --output-format stream-json`'s `result` message, which is a different architecture with
different costs (see below).

**Screen-scraping the TUI.** damson used to carry an orchestrator that matched spinner
glyphs, gerunds and input-box borders; its own header called that "a maintained fingerprint
set, NOT a stable protocol", and it broke on Claude Code releases. `claude agents --json` is
documented and returns `status` directly.

**Typing prompts into a pane.** `session.write` into a live TUI has **no delivery
acknowledgment of any kind** — the only ack Claude Code offers is `--replay-user-messages`,
which exists solely in headless stream-json mode. A prompt sent 200ms before the TUI reaches
its input box lands nowhere and damson cannot tell. Prompts go in argv. Claude Code's own
guidance also treats an agent driving its own pane as a blocked self-modification pattern.

**Impersonating iTerm2** to reach `claude --tmux`'s native-pane branch (the gate is
`if (!env.TMUX) return false; if (env.TERM_PROGRAM !== "iTerm.app") return false;`). Every
other TUI would then probe damson for iTerm2 escape sequences it does not implement.

**Widening `PaneNode.Kind`** for a non-terminal agent view (rendering stream-json as
structured UI). It is 63 coupled sites across 7 files, and it permanently forfeits keeper
survival: `handOffAll` needs a PTY master to pass, and a headless agent has none.

---

## 6. Where the code lives

| | |
|---|---|
| `Sources/DamsonAgents` | `AgentBadge`, `ClaudeSessionRegistry`, `PaneRegistry`, `AgentLaunch` — window-free, tested |
| `Sources/damson/CrewController.swift` | the AppKit glue: the 3s sweep, badge application |
| `Sources/damson/PaneTreeView.swift` | the per-pane status pill (`setAgentBadge`) |
| `Sources/DamsonControl/Wire.swift` | `spawnPane` / `listAgents` / `paneInfo`, `PaneTarget` |
| `Sources/damson/SessionRestore.swift` | `paneID` / `argv` persistence, the cold path |
| `Tests/DamsonAgentsTests` | vocabulary, registry, launch/restart argv |
| `Tests/DamsonControlTests/PaneAddressingWireTests.swift` | wire compatibility |

`DamsonAgents` is a target, **not** a library product: damson's own logic, not a contract
with downstream consumers. Promoting it later is easy; un-publishing an API is not.
