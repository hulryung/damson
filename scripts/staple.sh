#!/usr/bin/env bash
# staple.sh <path> — staple a notarization ticket into an .app or .dmg, then validate.
#
# The ticket is fetched from Apple's CloudKit, so a dropped connection ("The network
# connection was lost", exit 68) or a ticket that hasn't propagated yet right after
# notarytool reports Accepted fails an otherwise good release. Both are transient:
# retry with a growing pause before giving up. Notarization itself is not repeated.

set -euo pipefail

TARGET="${1:?usage: staple.sh <path to .app or .dmg>}"
ATTEMPTS="${STAPLE_ATTEMPTS:-5}"

for ((i = 1; i <= ATTEMPTS; i++)); do
    if xcrun stapler staple "$TARGET" && xcrun stapler validate "$TARGET"; then
        exit 0
    fi
    if ((i < ATTEMPTS)); then
        pause=$((i * 15))
        echo "==> staple attempt $i/$ATTEMPTS failed; retrying in ${pause}s" >&2
        sleep "$pause"
    fi
done

echo "error: stapling $TARGET failed after $ATTEMPTS attempts" >&2
exit 1
