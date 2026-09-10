---
name: damson-orchestration
description: >-
  Coordinate coding agents in Damson terminal tabs, including building an app or game
  through task decomposition, parallel implementation, integration, and verification.
  Use when the user asks to orchestrate or parallelize work in Damson, run agents in
  labelled tabs, or monitor a Damson crew. Also supports interactive agent sessions.
---

# Orchestrating work in Damson

Use Damson's public CLI to keep delegated work visible in real terminal panes. You are the
coordinator: translate the user's requested outcome into tasks, supervise execution, and
verify the integrated deliverable. A collection of opened tabs is not evidence that a
product was built.

## Resolve the installed tools

Find `damson-cli` and `damson-crew` on PATH, then in
`/Applications/Damson.app/Contents/Resources/`, then `.build/debug/` in a Damson checkout.
Read the selected binaries' `--help`; use `damson-crew workflow --help` for managed work.
Confirm `damson-cli --list-instances` finds a running app. Use `--pid` if the user selected
an instance; otherwise the newest instance is used. Do not silently replace Damson with
bare PTYs or background jobs when tools or the app are unavailable.

## Choose the execution mode

**A deliverable to complete**, such as “build a game with multiple agents”: use managed
`workflow run`. Finite commands run in panes and publish durable exit/validation results.
Dependencies, bounded retries, concurrency, and coordinator resume belong to this mode.
Read [references/workflows.md](references/workflows.md) for the plan schema and commands.

**Interactive agents the user wants to take over**: use the existing `run`/`watch` mode.
It opens sessions and routes attention to an agent waiting for input. It does not schedule
dependent work: `idle` can mean finished, never prompted, or a question awaiting an answer.
Read [references/interactive.md](references/interactive.md) for its command shape and limits.

## Completing a managed request

Establish a concrete final check appropriate to the user's request. For a game, this means
playable controls and game-state transitions in a real browser, as well as logic tests.
Choose reasonable defaults for details the user left open; ask only for missing decisions
that prevent useful progress.

Keep the plan compact: reference a shared contract and named test files instead of repeating
large inline validation programs in every task's argv. Include only the instructions each
worker needs. Finish planning once the graph validates; leave implementation and execution
to their assigned stages when the user asked only for a plan.

Write a plan and a shared interface contract before parallel implementation. Give each
worker clear file ownership, inputs, expected outputs, and tests. Use separate directories
or worktrees for conflicting edits. `resources` serializes tasks that share mutable state;
parallel agents in one directory must own disjoint files. Include integration and final
verification tasks with dependencies on their inputs. Worktree creation/merging can be
explicit finite tasks, using the existing worktree support when appropriate; do not merge
unreviewed outputs into the user's active branch.

For Claude workers, use finite `--print` execution. A `prompt` task without an explicit
command defaults to that mode; every prompt task requires `verify` commands. Choose
substantive checks that can fail for a broken deliverable, not only file existence or the
agent saying it succeeded. Include the final integration checks in the graph.

Run `workflow run` and stay with its process until completion or a concrete blocker.
The coordinator can stop and resume with the same plan and state directory; workers
continue during its absence. Never start a second state directory merely because an
observation timed out. Inspect `workflow status`, attempt logs, and the original process.

On failure, inspect the task's retained command/validation log. Automatic retries are
bounded by `maxAttempts` and prompt workers receive the previous attempt's log path.
An interrupted worker is not automatically retried because its children might still be
running. Resolve those processes before retrying. If the plan itself needs correction,
preserve the existing state and work, account for any live workers, and write a new plan
and state directory with only the remaining work. Do not repeat successful side effects.

Finally inspect the actual artifact and exercise the user's main flow. Passing agent-written
tests is supporting evidence, not a substitute for this check. Fix observed defects within
the requested scope and repeat affected checks. Report the runnable artifact, how to run it,
and exactly what was verified. Do not claim completion from status labels alone.

## Control invariants

- Prompts go in argv, never `send-text` into a live TUI; that has no delivery acknowledgment.
- Address a known pane by ID, not a tab index that can move. `reveal-pane` focuses the exact
  pane across windows and splits; a stale ID must fail rather than select another pane.
- When spawning directly, use an idempotency key. An IPC timeout can still create a pane.
- Cleanup only the run's own tabs/worktrees. `close --remove-worktrees` never forces git
  removal and preserves user-created, shared, in-use, or dirty worktrees. Closing tabs also
  stops their programs; respect the user's existing authorization and ongoing work.
