# Computer control implementation audit

Status: **in progress; not release-ready yet** (2026-09-11).

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

## Outstanding completion gates

- Rerun the full native suite with the latest binary, including scrolling,
  stop/revoke, and interruption of a long text operation.
- Verify the packaged helper's launch and actual macOS permission identity;
  development-process inherited permissions are not sufficient evidence.
- Exercise Damson's Computer Control panel against that helper.
- Run the real Snake game via `computer-game.swift` and
  `test-computer-game.py`: start, trusted direction input, movement, pause,
  restart, and retained screenshots.
- Verify restart/duplicate helper behavior and failure cleanup through the CLI.
- Re-run affected checks after any changes and update this audit with final evidence.

The desktop tests are paused pending the user's indication that the desktop is
available. No release or merge has been performed.
