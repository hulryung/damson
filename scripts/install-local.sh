#!/usr/bin/env bash
# install-local.sh — one-shot install for local dogfooding.
# Build the release .app → code-sign → install to /Applications → launch.
#
# Defaults to ad-hoc signing (this Mac only, runnable on your own machine right away).
# For full Developer ID signing/notarization/distribution, use
# scripts/sign-and-notarize.sh — this script is solely for "installing on my Mac to
# try it out", so Sparkle auto-update / distribution to other Macs do not work.
#
# Environment variables:
#   SIGN_IDENTITY   — codesign -s value. Default "-" (ad-hoc).
#                     To sign with a Developer ID, e.g.:
#                     SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
#                     (check with security find-identity -p codesigning -v)
#   INSTALL_DIR     — install location. Default /Applications
#   MARKETING_VERSION — Info.plist version. Default 0.1.0
#   NO_LAUNCH=1     — do not launch after installing
#
# Usage:
#   ./scripts/install-local.sh
#   SIGN_IDENTITY="Developer ID Application: Daekeun Kang (TEAMID)" ./scripts/install-local.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
APP="$REPO_ROOT/dist/Damson.app"
ENTITLEMENTS="$REPO_ROOT/Resources/Damson.entitlements"
HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DEST="$INSTALL_DIR/Damson.app"

[[ -f "$ENTITLEMENTS" ]] || { echo "error: missing $ENTITLEMENTS" >&2; exit 1; }

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> sign: ad-hoc (this Mac only — no auto-update, no distribution)"
else
    echo "==> sign: $SIGN_IDENTITY"
fi

# 1) Build the release .app (CLEAN removes stale leftovers, git hash in BUILD_NUMBER).
echo "==> build release .app @ $HASH"
CLEAN=1 MARKETING_VERSION="$MARKETING_VERSION" BUILD_NUMBER="$HASH" \
    ./scripts/build-app.sh >/dev/null
[[ -d "$APP" ]] || { echo "error: build produced no $APP" >&2; exit 1; }

# 2) Code-sign — nested frameworks (Sparkle, etc.) first, then the app bundle.
#    Sign with Hardened Runtime (--options runtime) to match the release signing setup.
echo "==> codesign frameworks + app"
if [[ -d "$APP/Contents/Frameworks" ]]; then
    find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 \
        | while IFS= read -r -d '' fw; do
            codesign --force --options runtime --sign "$SIGN_IDENTITY" "$fw"
        done
fi
codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -1

# 3) Install — kill the running instance and replace it. Remove the quarantine bit
#    (usually absent for local builds, but if present it triggers a first-run Gatekeeper prompt).
echo "==> install to $DEST"
pkill -f "Damson.app/Contents/MacOS/damson" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> installed: $DEST  (0.1.0 / $HASH)"

# 4) Launch (can be skipped with NO_LAUNCH).
if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
    echo "==> launching"
    open -a "$DEST"
fi
