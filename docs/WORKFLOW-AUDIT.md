# Managed workflow acceptance audit

This work extends the previously verified fan-out/attention layer to complete a project
through finite agent tasks, dependencies, integration and checks. Tracked in #32.
Interactive badges remain observation only; no transition depends on `idle`.

## Required evidence

| Requirement | Current evidence |
| --- | --- |
| Validate the graph before executing anything | WorkflowTests and test-workflow-cli: cycles, unknown dependencies/fields, duplicate IDs, missing directories, invalid commands/timeouts. |
| Respect dependency order, parallelism and shared resources | WorkflowTests; live app executes two workers concurrently, integration waits for both. |
| Validate results, block descendants on failure | Real command/validator/output tests, CLI and isolated GUI failures. |
| Bounded retries preserve work and provide failure context | Real CLI retry test (two attempts, retained logs); prompt argv includes previous log; actual game UI timeout triggered a second attempt. |
| Coordinator restart cannot duplicate live/completed work | File locks, journal-before-spawn, per-attempt keys; real CLI and app restart-of-coordinator tests keep invocation counters at one. |
| Worker timeout and interruption have defined outcomes | Real process/descendant timeout tests; lost worker is failed without retry because its children may survive. |
| Consumer skill plans, supervises, integrates and verifies | Updated plugin 0.3.0, self-contained workflow/interactive references; skill validator passed. Behavioral end-to-end validation still pending. |
| Actual AI agents produce a playable game | In progress: engine completed, UI retried after timeout; integration/browser checks pending. |
| Existing functionality stays green | 272 Swift tests, one existing skip, zero failures; existing 10 CLI tests pass. |
| CLI integration is enforced in CI | Five new real-worker CLI tests pass locally; CI workflow updated. PR CI pending. |

## Reproduce

```sh
swift test --filter 'DamsonCrewTests|DamsonAgentsTests|DamsonControlTests'
python3 scripts/test-crew-cli.py .build/debug/damson-crew
python3 scripts/test-workflow-cli.py .build/debug/damson-crew
# Requires a macOS graphical session; launches and cleans up its own app.
python3 scripts/test-workflow-live.py
```

The GUI fixture verifies actual pane launch and finite worker execution, concurrency,
coordinator termination/resume, result validation, retry and timeout. It does not invoke
an AI provider and is not evidence of generated product quality. The separate actual-AI
exercise must finish integration and independent browser checks before this audit is complete.
