# Damson Computer

`damson-computer` is the CLI for Damson's macOS desktop helper. It controls a selected
GUI app; `damson-cli` still addresses terminal panes, and `damson-crew` still schedules
workflows. The helper is shared by all Damson instances owned by the current user.

## Build and start

```sh
./scripts/build-app.sh
dist/Damson.app/Contents/Resources/damson-computer start
```

The CLI is bundled in `Contents/Resources`. The separate **Damson Computer.app** is
bundled in `Contents/Helpers`, with bundle ID `app.damson.computer`. The release script
signs both before signing the outer app. Use the signed distribution at a stable path
for persistent macOS permissions. During development, `.build/debug/damson-computer
--serve` runs the helper directly; permissions granted to a parent terminal in this
mode do not prove that the distributed helper has permission.

In Damson, **Tools → Computer Control…** starts the helper, shows the current task and
permission state, and provides Stop/Resume controls. The helper also has a **DC** menu
bar item, so Stop remains accessible even when Damson is not frontmost.

Run `permissions` to check access and `permissions --prompt true` to request it. Grant
Accessibility and Screen Recording to the app macOS names in System Settings. Restart
the helper if macOS requests it. Nothing edits the TCC database or bypasses permission
prompts. Captures use ScreenCaptureKit on macOS 14+, with a macOS 13 fallback.

## A controlled session

Every response is JSON with `id`, `ok`, and `result` or `error`. Errors exit nonzero.
Read `--help` from the installed CLI for the exact command surface.

```sh
damson-computer apps
damson-computer acquire --pid 12345 --owner game-playtest --ttl 60
# Save result.token as SESSION. This is a capability; keep it within this task.
damson-computer focus --session "$SESSION"
damson-computer windows --session "$SESSION"
damson-computer inspect --session "$SESSION"
damson-computer capture --session "$SESSION" --window 456
# Use an element ID from the latest inspect, or point coordinates from its bounds.
damson-computer press --session "$SESSION" --element ELEMENT_ID
damson-computer key --session "$SESSION" --key space
damson-computer type --session "$SESSION" --text 'Hello 한글 🎮'
damson-computer renew --session "$SESSION" --ttl 60
damson-computer release --session "$SESSION"
```

`apps` discovers existing apps; launch a test app with the normal macOS launcher before
acquiring it. Sessions target PID plus launch identity, not a potentially ambiguous app
name. Reacquire after app restart. `focus` dispatches activation; observe that the app is
frontmost before input. Keys and AX presses refuse background targets. Coordinate clicks
also hit-test the target through Accessibility, rejecting another app's covering window.

`capture` requires an explicit window ID belonging to the target. It returns the PNG
path, global point bounds, pixel dimensions, and scale. Convert screenshot pixels to
click points with `x = bounds.x + pixelX / scaleX` and the equivalent for y. Display
coordinates start at the primary display's top-left and may be negative on other displays.
Captures exclude window shadows and are capped at 4096 pixels per dimension on macOS 14+.

`inspect` returns a bounded accessibility tree with element IDs, roles, labels, values,
bounds, and supported actions. Secure text-field values are omitted. IDs last until the
next inspection or session change; inspect again after UI changes. `press` invokes AXPress;
unsupported controls can be operated using inspected coordinates. Unicode typing leaves
the clipboard intact. Named key chords use macOS virtual keys (letter shortcuts assume
US key positions); use `type` for literal Unicode text.

## Ownership, cancellation, and failure

Only one session can own the desktop. TTL is 5–300 seconds; renew while actively working.
Lease expiry uses ContinuousClock (including elapsed sleep time), so changing the system
clock cannot extend or prematurely expire authority. Reported dates are display metadata.
An expired session, helper restart, or Stop invalidates its token. Existing artifact files
never restore authority. The helper's process lock and private user socket enforce this
across separate workflows; workflow `resources: ["desktop"]` is only a scheduling hint
inside one workflow and cannot replace the helper lease.

Physical mouse movement, clicks, scrolling, or keyboard input stop an active session.
The helper pauses and requires explicit Resume. **Agents must not automatically resume
a user stop.** Ask the user when to continue. A fresh lease is required after resuming.
Stop remains available during asynchronous capture and text input. Text input yields
between characters and checks authority and focus again. A stopped/failed type operation
may have inserted a prefix; inspect before making corrections.

Actions return `dispatched`, not application-level success. Inspect/capture and check the
actual application state before declaring success. A timeout/disconnect can happen after
an action executes: never blindly repeat clicks, typing, or shortcuts. `--request-id ID`
returns the cached response for the same request within the helper's last 256 completed
requests; conflicting use of an ID is rejected. This cache is intentionally not a durable
exactly-once guarantee across helper restarts. Observe after restart or cache eviction.

Sessions retain `session.json`, `actions.jsonl`, and PNGs under
`~/Library/Application Support/Damson/Computer/sessions/`. Input actions record an intent
before execution and a result afterwards; an intent without a result is uncertain. Typed
text is replaced with its length in request logs. Screenshots and inspected UI values can
contain target-app content, so review artifacts before sharing them. Release/Stop leaves
these records intact. No background upload occurs.

## Workflow integration

Give the UI verification task dependencies on build/start tasks. Its agent acquires the
helper session, operates the target, renews while needed, verifies results, and releases in
cleanup. Include a verifier that checks real app state as well as retained evidence. Fail
the task on denied permissions, user interruption, expired authority, or unmet app checks;
do not report success from `dispatched: true` or PNG existence alone.

The helper does not run a model or choose goals. The existing coding agent interprets
screenshots/AX trees and chooses actions. There is no second scheduler inside Damson.

## Tests

`swift test --filter DamsonComputerTests` covers exclusivity, expiry, renewal, stop/resume,
restart authority, strict argument validation, request deduplication, and public status.

`scripts/fixtures/computer-target.swift` is a disposable native test app. Bundle and launch
it, then run `python3 scripts/test-computer-live.py PATH_TO_CLI STATE_JSON`. The live test
checks native AX actions, real clicks and Unicode edits, screenshot generation, scrolling,
request deduplication, rejection of wrong targets, and cancellation. Run only while the
user has made the desktop available for the test. It never targets user documents.

`python3 scripts/test-computer-duplicate.py PATH_TO_CLI` checks duplicate helper
startup against an already paused helper. It performs no screen capture or input and
asserts that the existing PID and paused state remain unchanged. Startup failures
return a nonzero process exit code.
