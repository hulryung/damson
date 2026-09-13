# Interactive fan-out

```sh
damson-crew run --tasks tasks.json --group run-7
damson-crew status --tasks tasks.json --group run-7
damson-crew watch --tasks tasks.json --notify --focus
damson-crew close --group run-7 --yes
```

A task list is an array of `{name, prompt, cwd}` entries. Use `repo` and optional `branch`
and `base` instead of `cwd` to create/reuse a worktree. `command` overrides the agent;
`{prompt}` substitutes in argv, otherwise the prompt is appended last. Use binary `--help`
for current flags. Duplicate task names are rejected; separate groups may reuse names.
`run` reattaches by group/title after a restart and uses scoped spawn keys for retries.

Direct `damson-cli spawn` opens a new tab unless `--split-h`/`--split-v` is provided.
Pass `--key`, `--title`, and `--group`. Keys are in memory, so after an app restart inspect
existing panes before directly repeating a spawn. `run` handles that reattachment itself.

A run's tabs open in the window in front unless Settings → Agents → "Open each run in a new
window" is on; `--new-window` / `--no-new-window` override it for one run. In new-window mode
the run gets one window of its own, with its agents as the first tabs, and a later run of the
same group joins that window instead of opening another. `damson-cli spawn --window KEY` is
the primitive underneath: spawns sharing a key share a window, and a spawn whose group already
exists goes to the window holding it.

Permission prompts are bypassed for Claude by default, following Settings → Agents;
`--no-skip-permissions` overrides this per run. Explicit `--permission-mode` is respected.
Other agents are launched without Claude-specific flags. Defaults also cover worktree
location, notifications, and focus behavior.

The watching half is Claude-only. Other tools can run in panes but do not publish the
session records used for `waiting` alerts. `watch-agents` is an edge-triggered NDJSON stream
with an initial snapshot and a heartbeat every 20 seconds; silence alone means no change.
Only `waiting` warrants user escalation. `idle` is not task completion. For a deliverable
with dependent tasks, use managed workflows instead of adding an idle-driven scheduler.
