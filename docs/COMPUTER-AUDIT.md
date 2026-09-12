# Computer control implementation audit

Status: **in progress; not release-ready yet** (2026-09-12).

## Implemented

- Separate `damson-computer` CLI and app helper with stable bundle identity.
- User-wide helper lock/socket and exclusive target-app session, finite TTL/renewal.
- Target PID plus launch identity checks; explicit focus and foreground/AX hit tests.
- App/window discovery, bounded AX inspection, AXPress, clicks, Unicode typing,
  named keys, scrolling, window PNG capture with point/pixel mapping.
- Stop/resume, physical-input interruption, revocation between typed characters.
- Capture deadlines, off-main socket writes, request-ID deduplication, retained
  action intents/results and screenshots.
- Damson Tools management panel, helper menu bar control, build/sign packaging,
  workflow usage reference, and native/game acceptance fixtures.

## Evidence so far

- Full `swift test`: **760 tests, 24 skipped, 0 failures**. This includes 9 new
  Computer session/engine tests. Skips are existing platform/environment gates.
- Follow-up targeted suite: **15 Computer tests passed**, including clock-jump
  expiry/renewal and real CGEvent construction checks for Unicode, released modifiers,
  fractional/negative global coordinates, and explicit pixel-scroll location/deltas.
  These event tests do not post input and do not replace the pending native rerun.
- Existing CLI integration suites: **10 crew + 7 workflow tests passed**.
- SwiftLint: **0 errors**; existing and structural warnings remain.
- `test-computer-duplicate.py` passed against the live paused helper: a second
  helper exits with failure code 1, the original PID stays reachable, and its paused
  state and lack of session are preserved. No desktop input was posted.
- Production app bundle built successfully in an isolated temporary output folder.
- Development helper reports Accessibility and Screen Recording access.
- Native target confirmed AX button press, identical-request deduplication,
  coordinate click, cmd+a, exact `Damson 한글 🎮` text insertion, and window PNG capture.
- A physical-input event paused the helper and revoked an active token. The test
  stopped instead of resuming that user interruption automatically.

## Observed defects fixed during acceptance

1. Transparent Dock windows were mistaken for blocking windows. Click validation
   now uses Accessibility hit testing as well as target window bounds.
2. Modifier flags from a preceding shortcut prevented Unicode text insertion.
   Events now use a private source and explicitly clear modifier state.
3. Scroll events needed their target point set explicitly. Code is corrected;
   a full live rerun is still pending.

## Resumed acceptance (2026-09-11)

- Latest targeted suite: 16 Computer tests passed, including rejecting queued input
  that predates session acquisition. Zero-delta window-related mouseMoved events are
  excluded, and status retains the first pause reason rather than overwriting it
  during cleanup. External input diagnostics include the event source process ID.
- Native acceptance again reached Unicode typing and screenshot capture. The full
  run still failed at scrolling: the fixture did not receive a scroll event. A
  session-tap routing candidate is implemented but is not yet verified as a fix.
- A later run also exposed an acceptance sequencing issue: typing began without
  checking that cmd+a had selected the prior text. The fixture now observes actual
  editing/selection state, and the test waits for it before typing.
- During other runs, external mouse movement revoked the lease and another app
  (Markdown Prism's development build) became frontmost. Tests stopped; these are
  not passing playtests. A further uninterrupted desktop window was requested.
- The bundled CLI successfully launched the helper with bundle identity
  `app.damson.computer`. Unlike the development process, it reports both Accessibility
  and Screen Recording denied. Its macOS permission prompts have been requested;
  user grants are pending. The helper remains paused.
- The game observer was corrected to read the game's actual `data-status` attribute
  and assert Restart returns to ready before starting another round.

## Resumed audit (2026-09-12)

- Rechecked the packaged helper through its live CLI: PID 4834 responds, has no
  active session, is not paused, and still reports both Accessibility and Screen
  Recording denied. No desktop actions were sent; permission/readiness input was
  requested again for this resumed run.
- The native acceptance script now checks both permissions and desktop ownership
  before acquiring a session. It also starts a long text operation, observes a
  partial value in the fixture's actual editor, sends Stop while the helper is busy,
  and checks that the request fails, input stops, and the token is revoked. It
  refuses to resume a pause caused by external input. This new live check is
  **prepared, not passed**; it still needs the permitted packaged-helper run.
- Python compilation and `git diff --check` passed. The 16 selected
  `DamsonComputerTests` passed again with zero failures. These checks do not
  establish live scrolling, cancellation, game play, or permission identity.

## Permission discoverability (2026-09-12)

- Added a helper-owned Set Up Permissions window. Each permission button requests
  the matching macOS permission before opening its settings page. The window shows
  the running helper's path, copies it on request, and explains the + / Command-Shift-G
  fallback for a missing list entry. It polls actual permission state while visible.
- The Damson panel routes setup requests to the running helper rather than requesting
  permissions for the terminal process. DC menu settings entries also request the
  matching permission. Unknown setup sections are rejected before opening UI.
- Both executable builds and full app packaging succeeded; 17 Computer tests passed.
  The updated helper was installed at the existing temporary test path and its
  `setup-permissions` CLI returned `shown: true` (PID 92608). Permission grants and
  actual appearance in the macOS lists remain user-dependent and unverified.

## Permission list registration verified (2026-09-13)

- Read-only tccd logs identified stale ad-hoc code requirements for the helper.
  Installed the helper at `~/Applications/Damson Computer.app` and signed it with
  the existing Developer ID. Verified its designated requirement is based on
  bundle ID and signing team, not a build-specific cdhash.
- Reset only this helper's previously denied Accessibility/ScreenCapture records
  using tccutil; restarted it and made separate standard permission requests.
  Selected only Open System Settings in the macOS request dialogs, never Allow
  or a permission switch. No TCC database was edited.
- Orca's live System Settings AX tree confirmed Damson Computer exists in both
  Accessibility and Screen & System Audio Recording, with both switch values 0.
  Helper PID 69266 responds at the stable installed path, with both permissions
  false and no active session. This establishes registration, not granted access
  or successful desktop control. Existing native/game completion gates remain.

## Packaged-helper input acceptance (2026-09-13)

- After the user enabled access, restarting the same signed installed helper made
  both permission checks true (PID 69549). Native fixture rebuilt from current source.
- The native test confirmed exclusive ownership, argument rejection, AXPress with
  duplicate-request suppression, coordinate clicks, cmd+a, exact `Damson 한글 🎮`
  input, capture, and rejection of an out-of-window click. The retained PNG was
  visually inspected and shows Count: 2 and the exact input string.
  Evidence: `~/Library/Application Support/Damson/Computer/sessions/509EC175-C1B1-46D7-A73F-FBED238C0AF9/`.
- The run then failed with `focus_changed` before scrolling. The test now explicitly
  focuses the fixture again after capture and waits for actual foreground state.
  This revised sequence has not passed yet.
- The next attempt stopped before focus due to external mouse movement
  (`external_input:NSEventType(rawValue: 5):sourcePID=0`). The helper stayed paused
  with no lease; no automatic resume was attempted after that interruption.
- Requested another uninterrupted test window. Scroll, long-input cancellation,
  game play, panel interaction, and CLI restart/revocation still need live evidence.

## Continued native debugging (2026-09-13)

- Reproduced the scroll failure with the current signed helper: the command returned
  success, but the fixture recorded no scrollWheel events and its scroll offset
  stayed at zero. Changed scroll posting from the session tap to the already
  validated foreground target PID. This is a candidate fix, not a verified pass.
- Instrumented the native fixture's actual key/mouse events. Cmd+A arrived with
  the Command flag, but the bare fixture lacked a standard Edit/Select All menu.
  Added the real responder-chain Select All action so nonempty selection and the
  long-input cancellation sequence can be tested meaningfully.
- Rebuilt and installed the scroll candidate at the existing Developer-ID-signed
  helper path; both permissions survived the update. Release build and 17 selected
  Computer tests passed; these do not prove delivery to an actual app.
- The next native run was interrupted by external mouse movement before its
  ownership check completed. Helper PID 69958 remains paused with no active lease.
  Asked for another input-free test interval; did not resume that interruption.

## Outstanding completion gates

- Rerun the full native suite with the latest binary, including scrolling,
  stop/revoke, and interruption of a long text operation.
- Verify the packaged helper's launch and actual macOS permission identity;
  development-process inherited permissions are not sufficient evidence.
- Exercise Damson's Computer Control panel against that helper.
- Run the real Snake game via `computer-game.swift` and
  `test-computer-game.py`: start, trusted direction input, movement, pause,
  restart, and retained screenshots.
- Verify helper restart invalidation and failure cleanup through the CLI.
  Duplicate startup exclusion is already verified.
- Re-run affected checks after any changes and update this audit with final evidence.

The desktop tests are paused pending the user's indication that the desktop is
available. No release or merge has been performed.
