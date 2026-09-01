---
name: damson-orchestration
description: >-
  Run several coding agents as labelled tabs inside a running damson terminal, watch them,
  and tear the run down. Use when the user says "run these tasks in damson", "fan out
  agents", "a tab per task", "open agents in damson", "watch the agents", "which agent is
  blocked", "damson-cli", "damson-crew", "group the tabs", or asks to orchestrate/parallelise
  work across terminals on this machine. Prefer this over spawning bare PTYs, tmux, or
  background `claude -p` when the user wants to SEE the agents and take one over.
---

# Orchestrating agents in damson

damson can open, address and observe panes running `claude`. The reasoning, the wire format
and everything that was measured and rejected live in `docs/CLAUDE-ORCHESTRATION.md` in the
damson repo — read it before proposing anything structural.

**The one thing to internalise: this is fan-out and attention routing, not a queue.**
Measured against Claude Code 2.1.251, a terminal state (`done`/`failed`) exists only for
`kind: background` sessions, which carry no pid and therefore no pane. The `kind: interactive`
sessions that live in panes never carry one at all. So a visible tab a human can take over
and a completion signal are **alternatives, not a pair**. Never build a scheduler that
advances on `status: "idle"` — it also means "asked you a question" and "never prompted".

## Resolve the binaries first

`damson-cli` is **not necessarily on PATH**: it ships inside the app bundle, and only
`scripts/install-local.sh` links it. In this order:

1. `damson-cli` if it runs.
2. `/Applications/Damson.app/Contents/Resources/damson-cli`.
3. In a damson checkout, `.build/debug/damson-cli` (build it with `swift build`).

`damson-crew` is only in a checkout (`.build/debug/damson-crew`) unless the user installed it.
If neither exists and the user wants orchestration, say so rather than falling back to
something else — a bare PTY is not the thing they asked for.

Confirm an instance exists before anything else: `damson-cli --list-instances`. Address a
specific one with `--pid`; the default is the most recent.

## Don't guess flags

`damson-cli --help` and `damson-crew --help` are the authoritative surface and are printed by
the binary that will run your commands. Read them instead of recalling flags — this file
deliberately does not list them, so it cannot drift.

The shape worth knowing:

- **`spawn` opens a NEW TAB** unless you pass `--split-h`/`--split-v`.
- **Always pass `--key`.** damson's control handler reports a timeout at 2s *while the queued
  work still completes*, so a slow spawn answers "failed" for a tab that did open. Without a
  key, a retry mints a second agent.
- **`--title` and `--group`** make the tabs tellable apart and closable as a unit. A group's
  tabs are kept contiguous, so a late joiner is relocated next to the others.
- **`watch-agents` is a stream, not a poll.** Snapshot first, then edge-triggered changes,
  with a `heartbeat` line every 20s. Silence means nothing changed.
- **`--pane <id>`** addresses any pane in any window. A stale id is a typed error, never a
  fallback to the active pane.

## Rules that are not optional

- **Prompts go in argv, never typed into a pane.** `send-text` into a live TUI has *no
  delivery acknowledgment*; a prompt that races the TUI's input box is lost and nothing can
  tell. `damson-crew` puts the prompt in argv for this reason.
- **`--key` does not survive a damson restart** — the table is in memory. Before re-running a
  task list, ask what is already on screen (`damson-crew status`, or `agents`) and open only
  what is missing. Skipping this duplicated a three-task run into six tabs.
- **Escalate only `waiting`.** It is the one state that will not resolve without the user.
  Alerting on anything else trains them to dismiss the one that mattered.
- **`group close` is destructive** — several tabs and the programs in them. Confirm with the
  user first; `damson-crew close` requires `--yes` for this reason.

## The usual shape

```sh
damson-crew run    --tasks tasks.json --group run-7   # a labelled tab per task
damson-crew status --tasks tasks.json --group run-7   # exits non-zero if one is blocked
damson-crew watch  --tasks tasks.json --notify --focus
damson-crew close  --group run-7 --yes
```

A task is `{"name", "prompt"}` plus where to run: either `"cwd"`, or `"repo"` with optional
`"branch"` and `"base"`, in which case damson-crew makes a git worktree and uses it. `name`
is both the tab label and the spawn key, so it must be unique — a duplicate silently
collapses two tasks into one pane.

## Any agent, not just claude

`"command"` overrides the agent. The prompt is appended as the **last argument**, which
`claude`, `codex`, `grok` and `cursor-agent` all take; put `{prompt}` in the command for a
tool that wants it behind a flag.

Make the worktree here rather than reaching for the agent's own flag. Support is per-tool and
inconsistent — `claude -w`, `grok --worktree=<name>`, nothing in `codex` or `cursor-agent` —
so a task list that used them would only work for some of its tasks.

**Permission prompts are bypassed by default.** `damson-crew` passes
`--dangerously-skip-permissions` to `claude`, because an agent stopped on an approval is the
most common way a fan-out stalls — the tabs look alive while every one of them waits for a
keypress. It means agents edit files and run commands without asking. `--no-skip-permissions`
turns it off for a run; Settings → Agents changes the default. It applies to `claude` only:
other agents spell this differently or not at all, and passing a flag a CLI does not know
turns a working spawn into a pane that exits instantly.

A caller who already wrote `--permission-mode` is never overridden.

**Defaults come from Settings → Agents** — the agent command, the bypass, whether a blocked
agent notifies, and where worktrees go. Every one can be overridden per run with a flag.

**`close --remove-worktrees` never forces.** git refuses to remove a worktree holding
uncommitted or untracked files; report that refusal, never work around it. Those files are
the agent's work and they are uncommitted exactly when losing them would matter most.

**The watching half is Claude-only.** `watch`/`--notify` join panes to Claude Code's session
records. Agents from other tools open, get labelled and grouped, and run — but never raise a
`waiting` alert, because nothing publishes that state. Say so rather than letting someone
plan a run around alerts that will not arrive.
