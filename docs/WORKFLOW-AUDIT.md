# Managed workflow acceptance audit

PR #33 / issue #32 extends interactive fan-out to complete projects through finite agent
tasks, dependencies, integration and checks. No transition depends on an `idle` badge.
The coordinator skill owns planning and final review; the CLI executes the resulting graph.

## Evidence against the requested outcome

| Requirement | Evidence |
| --- | --- |
| Validate a graph before executing anything | WorkflowTests and CLI tests reject cycles, unknown dependencies/fields, duplicate IDs, missing directories and invalid commands/timeouts without contacting the app or creating state. `workflow validate` works without an app. |
| Respect dependencies, parallelism and shared resources | Model tests plus real workers in an isolated app: two workers run concurrently and integration waits for both. |
| Check results and block descendants on failure | Real command/validator/output tests, CLI tests and app tests; command exit 0 cannot bypass a failed validator or missing output. |
| Retry within a bound while preserving files and feedback | CLI invocation counters prove the attempt bound; separate logs are retained and prompt retries receive the previous log path. The actual game UI hit its 480-second limit, then completed on attempt 2. |
| Resume without duplicating live or completed attempts | Journal-before-spawn, attempt keys and descriptor locks; real CLI/app tests terminate and resume the coordinator while two workers stay live, keeping their invocation counts at one. |
| Handle timeout and worker loss explicitly | Real command-process-group timeout tests. A CLI test kills the wrapper while its command survives: the task fails once, reports the surviving command using PID plus kernel start time, and does not retry. PID reuse is rejected. |
| Turn natural-language intent into an executable plan | A Claude planner read the updated skill and produced a memory-card-game contract and four-task graph: engine + interface → integration → browser play check, maxParallel 2, disjoint file ownership and substantive validators. The actual `workflow validate` command and enclosing managed task both succeeded. |
| Produce a real integrated game using AI workers | Actual Claude workers wrote a dependency-free Canvas Snake game: engine, interface and integration. Each ultimately published a structured provider success result. Recovery and verification details are below. |
| Verify the delivered game independently | 46 generated integration tests and 7 independently authored engine tests pass. Real Chromium checks pass for desktop start/steer/pause/resume/gameover/restart, keyboard input, and mobile touch controls at 390px without horizontal overflow. No JS exceptions or external requests. Final screenshots were inspected. |
| Preserve existing behavior | 273 Swift tests: one existing skip, zero failures. The existing 10 CLI tests pass. |
| Enforce the new execution path in CI | Seven real-worker CLI tests pass and are included in `.github/workflows/crew-tests.yml`. Final PR checks must be green before review readiness. |

## Actual failures and recovery

The game exercise was not one uninterrupted all-green run. A too-short test harness
supervision budget prompted an attempted supervisor replacement. The execution tool then
terminated the app and worker wrapper along with that supervisor. The integration Claude
command survived. Resuming the original workflow correctly sealed integration as failed,
without duplicating its surviving command or replaying the completed engine/interface.

The surviving original command was observed until it ended and wrote a structured Claude
success result. Its lost wrapper could not supply a process exit status, so no success was
inferred for that original attempt. A new **verification-only** managed workflow ran the
46 integration tests, seven independent tests and desktop/mobile browser checks, and
succeeded. Original failure and recovery success journals are preserved separately.

This incident drove the kernel process identity record and real orphan-command regression.
Commands that outlive a lost wrapper are reported for inspection, not automatically rerun.

An initial planning-only exercise produced a valid but excessively verbose plan and then
hit its 600-second limit. It remains a failed attempt. The skill was refined to reference
contracts/test files rather than duplicate large inline programs. A fresh planning exercise
with Claude's `medium` effort produced a compact valid plan and exited successfully in
about 137 seconds. Both plan content and dependency/file-ownership semantics were inspected;
provider performance is not assumed identical across effort settings or projects.

## Reproduce the deterministic checks

```sh
swift test --filter 'DamsonCrewTests|DamsonAgentsTests|DamsonControlTests'
python3 scripts/test-crew-cli.py .build/debug/damson-crew
python3 scripts/test-workflow-cli.py .build/debug/damson-crew
# Requires a macOS graphical session; launches and cleans up its own app.
python3 scripts/test-workflow-live.py
```

The GUI fixture checks actual panes and finite worker execution but invokes no AI. The
separate real-agent game, plans, screenshots and selected verification output are retained
locally in `/Users/dkkang/dev/damson-artifacts/orchestration-2026-09-10/`. Its report explains
how to play/test the game and distinguishes the interrupted run from recovery. The browser
harness uses the local test Playwright installation; the game itself needs no packages.

The installed release has not been replaced by this audit. Adoption requires the new CLI
and plugin; the app's terminal/control substrate remains compatible and independent.
