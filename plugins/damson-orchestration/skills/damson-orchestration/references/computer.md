# Desktop verification with Damson Computer

Resolve `damson-computer` on PATH or beside `damson-crew` in the selected Damson app's
`Contents/Resources`. Read `--help`. `start` launches its bundled helper; `status` reports
permissions and current owner. If permission is missing, request it with `permissions
--prompt true` and wait for the user to grant the macOS permission. Do not bypass it.

1. Launch only the task's test app using the normal launcher. Use `apps` to identify its
   PID. `acquire --pid PID --owner TASK_NAME --ttl 60` returns `result.token` and artifacts.
2. Pass `--session TOKEN` on each session command. Explicitly `focus`, then observe before
   input. `windows` lists target window IDs; `inspect` returns AX element IDs and bounds.
3. Use `capture --window ID` for a PNG. Read the image. Coordinates are global desktop
   points; convert pixels using returned bounds and scale. Prefer `press --element ID`
   for an actionable AX control, then `click --x X --y Y` when necessary.
4. `key --key space`, `key --key cmd+a`, `type --text TEXT`, and `scroll --dy -150` operate
   the selected app. A successful command only means dispatched. Inspect/capture and
   verify the expected transition before moving on.
5. `renew --ttl 60` before expiry. `release` in cleanup. Never share the token with another
   task. A helper restart needs a new lease and fresh observation.

`busy` means another task owns the desktop; keep doing independent work or wait for it.
Never stop another task to take its lease. TTL is 5–300 seconds. Workflow `resources`
only coordinates that workflow; the helper lease is the cross-workflow authority.

**On user mouse/keyboard input, the helper stops and pauses. Do not automatically call
resume or acquire again. Ask the user when the desktop is available.** After explicit
Resume, acquire a new session and inspect current state. Interrupted typing may be partial.

On timeout/disconnect, the action might have run. Observe before retrying. Reuse the same
`--request-id` only for the identical request while the helper still retains it (last 256
completed requests). Deduplication does not survive helper restart. Do not replay an old
plan of clicks after the screen changed.

Retain the session's actions.jsonl, relevant PNGs, and an independent verifier result.
Do not equate PNG existence, an idle agent, or `dispatched: true` with a passing playtest.
