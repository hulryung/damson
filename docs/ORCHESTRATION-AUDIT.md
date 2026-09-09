# Orchestration reliability audit

The user-facing contract is the README's fan-out and attention routing: start one task per
tab, keep runs separate, retry without duplicates, observe agents, bring blocked work to
the user, and clean up without losing unrelated or uncommitted work. This audit is not a
claim that passing the existing unit tests proves all of that contract.

## Evidence recorded on 2026-09-10

- Crew, Agents and Control suites: 254 tests, one existing environment-dependent skip,
  zero failures. Includes deterministic regressions that failed before the fixes for
  group scope, option pairs, cleanup errors, same-second session updates, and worktree paths.
- `python3 scripts/test-crew-cli.py .build/debug/damson-crew`: ten passing CLI integration
  tests against an isolated socket and disposable git repositories.
- `python3 scripts/test-crew-live.py --pid <running-app-pid>`: passed against the installed
  running Damson. It exercised real process launch, retry, named-group isolation, partial
  spawn failure, status and group close. Three local shell fixtures each ran exactly once;
  all test panes were removed and pre-existing panes remained. No external AI was invoked.
- `test-crew-watch-live.py` passed against a separately packaged current-build app, with
  synthetic records from live fixture processes: busy → waiting → busy → idle → vanished,
  task names, exact-pane focus, and reconnect of the same watcher to a new app PID.
- `test-crew-watch-live.py --graceful-restart` repeated that flow with a normal quit/relaunch,
  confirming that the saved pane ID restores and `run` reattaches without duplication. This
  run used an isolated Foundation home, preferences domain, session directory and socket.
- Both isolated-app runs also passed shared-worktree protection, dirty-tree preservation,
  and cleanup retry after the group had already closed. All fixture apps/records were removed.
- Atomic reveal was also verified in a separately packaged current-build app with an isolated
  bundle identity and control socket: two windows, an inactive split, and a closed pane ID.
  The owning window became frontmost and pane-info identified the requested leaf as active.
  `test-crew-live.py --check-reveal` passed tab/split selection and stale-ID preservation.

## Requirements and remaining verification

| Requirement | Current evidence / remaining work |
| --- | --- |
| Tasks launch in their requested directories with intact argv | Real CLI smoke and coordinator/flag tests; #19, #24 fixed in PR #25. |
| Named and ungrouped runs do not absorb each other's tasks | Scoped-key tests and exact-group status regression; #26 fixed in PR #25. |
| Partial failure does not abort remaining work; retry does not duplicate | Real-app smoke and unit tests. |
| Worktree creation/reuse supports human paths | Real git regression with Unicode, quotes, backslash, newline and a custom root; #27 fixed in PR #25. |
| Cleanup validates input, reports failure and keeps dirty trees | CLI integration and git integration tests; #20, #22 fixed in PR #25. |
| Cleanup preserves pre-existing and shared worktrees | Per-worktree ownership records, repository flock, last-owner cleanup and live-pane checks implemented. Real git, parallel CLI processes, other-instance lookup failures and isolated-app lifecycle passed. #30 fixed in PR #25. |
| Agent observations notice session changes | Registry tests including equal-size subsecond rewrites plus live observer-to-watcher integration passed. #28 fixed in PR #25. |
| Watcher reconnects and resumes naming/focus requests | Injectable-stream/client tests plus the same live watcher surviving both forced and graceful app restarts passed. #21 fixed in PR #25. |
| Blocked work is revealed in the correct window, tab and split | Atomic reveal-by-ID implemented for both window controllers; wire/client tests and live two-window/split/stale-ID validation passed. #29 fixed in PR #25. |
| Alerts and turn-finished events are delivered with meaningful names | Live named WAITING/resumed/FINISHED/ended output and --focus passed. The production notification AppleScript compiles; notification visibility follows macOS preferences, and live fixtures disable toasts. |
| Regression gates run automatically | macOS crew-tests and SwiftLint workflows on PR #25; final commit checks must be green before completion. |

## Commands

```sh
swift test --filter 'DamsonCrewTests|DamsonAgentsTests|DamsonControlTests'
swift build --product damson-crew
python3 scripts/test-crew-cli.py .build/debug/damson-crew
# Opt-in: briefly opens fixture tabs in a running app, then removes its own groups.
python3 scripts/test-crew-live.py --pid PID --check-reveal
# Isolated GUI app, no AI/API calls; requires a macOS graphical session.
python3 scripts/test-crew-watch-live.py
# Additionally verify persisted pane IDs after a UI-driven normal quit (requires Orca).
python3 scripts/test-crew-watch-live.py --graceful-restart
```

All functional requirements above now have direct code/test/runtime evidence. Remaining
release gate: verify the final PR commit's CI checks. The feature remains fan-out and
attention routing, not a completion-driven task queue. External AI authentication and macOS
notification preferences are outside these fixture tests. Workspace trust changes are now
restricted to Claude tasks (#31), with a regression for non-Claude commands.
