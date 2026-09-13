Run coding agents as visible tabs in the Damson terminal, and see the work through.

You are the coordinator. Opened tabs are not evidence that anything was built: decide what
"done" means for this request, then check it yourself before reporting success.

## Tools

`damson-cli` and `damson-crew` are on PATH (symlinked from
`/Applications/Damson.app/Contents/Resources/`). Read their `--help` — and
`damson-crew workflow --help` — rather than guessing flags. Confirm an app is running with
`damson-cli --list-instances`; pass `--pid` to pick one, otherwise the newest is used.
Never quietly fall back to bare PTYs, tmux or background `claude -p`: the point is that the
user can see each agent and take one over.

## Pick a mode

**Dependent work with a deliverable** ("build X with several agents"): `damson-crew workflow
run --plan plan.json --state DIR`. Finite commands publish durable results; dependencies,
bounded retries and coordinator resume live here. `workflow status --state DIR` reports.

**Agents the user will talk to**: `damson-crew run --tasks tasks.json --group NAME`, then
`damson-crew watch --notify --focus`. This mode schedules nothing: `idle` means finished,
never prompted, or waiting for an answer — you cannot tell which from the outside.

## Task list

A JSON array. Each task needs `name`, `prompt`, and somewhere to run:

```json
[
  {"name": "review-api", "cwd": "/Users/dkkang/dev/myproj", "prompt": "…"},
  {"name": "fix-parser", "repo": "/Users/dkkang/dev/myproj",
   "branch": "agent/fix-parser", "base": "main", "prompt": "…", "command": ["codex"]}
]
```

- `cwd` runs in that directory; several agents then share one working tree.
- `repo` (+ optional `branch`, `base`) makes a git worktree per task — use it whenever two
  agents would otherwise edit the same files.
- `command` overrides the agent; the prompt is appended last, or substituted for `{prompt}`.
- `name` is the tab label and scopes the spawn key: re-running a list reattaches to the tabs
  that exist and starts only what is missing, so a retry never duplicates agents.

## What to expect

- Tabs are grouped by `--group`; `damson-cli group close NAME` or
  `damson-crew close --group NAME --tasks FILE --yes [--remove-worktrees]` ends the run.
- Where tabs open follows Settings → Agents → "Open each run in a new window"; override per
  run with `--new-window` / `--no-new-window`.
- Claude Code asks before working in a directory it has not seen. `damson-crew` pre-accepts
  that only for worktrees it created, so a run pointed at an unfamiliar `cwd` stalls with
  every agent waiting on the same prompt. Prefer `repo`, or a directory already in use.
- `--dangerously-skip-permissions` is on by default (Settings → Agents); agents will edit
  files and run commands without asking. `--no-skip-permissions` turns it off for one run.

## Driving the desktop from a run

`damson-computer` operates real windows, so a task can check its own work in the app it just
built. `status` reports permissions and who holds the desktop; `start` launches the helper.
Grant macOS permissions when asked — never work around them.

One desktop, many agents, so it is leased: `acquire --pid PID --owner TASK --ttl 60` returns
a token, and every later command takes `--session TOKEN`. `busy` means another task holds it
— do independent work or wait, never take the lease away. `renew` before the TTL expires,
`release` when done.

Observe, act, observe: `windows` and `inspect` to find the target, `capture --window ID` to
look, then `press --element ID` (preferred) or `click --x X --y Y`, `type`, `key`, `scroll`.
A command that reports `dispatched` only means it was sent — capture again and check the
screen actually changed before moving on.

If the user touches the mouse or keyboard the helper pauses. Do not resume it yourself: ask
whether the desktop is free, and after an explicit resume, acquire again and re-observe,
because half-typed input may be sitting there.

Deeper reference, if the checkout is present:
`~/dev/damson/plugins/damson-orchestration/skills/damson-orchestration/references/`
(`interactive.md`, `workflows.md`, `computer.md`).
