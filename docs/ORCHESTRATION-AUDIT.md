# Orchestration reliability audit

The user-facing contract is the README's fan-out and attention routing: start one task per
tab, keep runs separate, retry without duplicates, observe agents, bring blocked work to
the user, and clean up without losing unrelated or uncommitted work. This audit is not a
claim that passing the existing unit tests proves all of that contract.

## Evidence recorded on 2026-09-10

- Crew, Agents and Control suites: 245 tests, one existing environment-dependent skip,
  zero failures. Includes deterministic regressions that failed before the fixes for
  group scope, option pairs, cleanup errors, same-second session updates, and worktree paths.
- `python3 scripts/test-crew-cli.py .build/debug/damson-crew`: seven passing CLI integration
  tests against an isolated socket and disposable git repositories.
- `python3 scripts/test-crew-live.py --pid <running-app-pid>`: passed against the installed
  running Damson. It exercised real process launch, retry, named-group isolation, partial
  spawn failure, status and group close. Three local shell fixtures each ran exactly once;
  all test panes were removed and pre-existing panes remained. No external AI was invoked.
- The live smoke test uses the current crew binary with the installed app. It does not prove
  newly changed app-side observer code, cross-window focus, or app-restart behavior.

## Requirements and remaining verification

| Requirement | Current evidence / remaining work |
| --- | --- |
| Tasks launch in their requested directories with intact argv | Real CLI smoke and coordinator/flag tests; #19, #24 fixed in PR #25. |
| Named and ungrouped runs do not absorb each other's tasks | Scoped-key tests and exact-group status regression; #26 fixed in PR #25. |
| Partial failure does not abort remaining work; retry does not duplicate | Real-app smoke and unit tests. |
| Worktree creation/reuse supports human paths | Real git regression with Unicode, quotes, backslash, newline and a custom root; #27 fixed in PR #25. |
| Cleanup validates input, reports failure and keeps dirty trees | CLI integration and git integration tests; #20, #22 fixed in PR #25. |
| Cleanup preserves pre-existing and shared worktrees | Not satisfied: branch lookup does not track ownership or active users. #30 remains open. Include retry after an already-closed group's cleanup fails. |
| Agent observations notice session changes | Registry tests including equal-size subsecond rewrites; #28 fixed in PR #25. Live observer integration is still needed. |
| Watcher reconnects and resumes naming/focus requests | Injectable-stream/client tests; #21 fixed in PR #25. Live reconnect and event-delivery verification remains. |
| Blocked work is revealed in the correct window, tab and split | Not satisfied: two-request tab-index focus can select the wrong window or split. #29 remains open. |
| Alerts and turn-finished events are delivered with meaningful names | Board/escalation tests cover decisions; live end-to-end delivery and naming scope remain to be verified. |
| Regression gates run automatically | macOS crew-tests and SwiftLint workflows on PR #25. Recheck them after every pushed change. |

## Commands

```sh
swift test --filter 'DamsonCrewTests|DamsonAgentsTests|DamsonControlTests'
swift build --product damson-crew
python3 scripts/test-crew-cli.py .build/debug/damson-crew
# Opt-in: briefly opens fixture tabs in a running app, then removes its own groups.
python3 scripts/test-crew-live.py --pid PID
```

Next implementation priorities are #29 (atomic pane reveal) and #30 (ownership-aware
worktree lifecycle), followed by live observer/reconnect validation in an isolated app
instance. Do not mark orchestration complete while these requirements remain unverified.
