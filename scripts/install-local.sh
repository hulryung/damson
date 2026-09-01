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

# 2b) Refuse to run from inside the app being replaced.
#     Step 3 kills the running damson and only then removes and re-copies the bundle. Run
#     from a terminal hosted BY that damson, the kill takes this script's own shell with it,
#     part-way through — the app is deleted and never replaced, leaving no damson at all.
#     Dogfooding means the maintainer's terminal usually IS the app under test, so this is
#     the normal case, not a corner one.
ancestor_is_target() {
    local pid=$$ target_inode
    target_inode="$(stat -f %i "$DEST/Contents/MacOS/damson" 2>/dev/null || echo -)"
    [[ "$target_inode" == "-" ]] && return 1
    for _ in {1..24}; do
        local exe
        exe="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        if [[ "$exe" == "$DEST/Contents/MacOS/damson" ]]; then return 0; fi
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [[ -z "$pid" || "$pid" == "0" || "$pid" == "1" ]] && break
    done
    return 1
}
if ancestor_is_target; then
    cat >&2 <<MSG
error: this shell is running inside $DEST, which this script is about to replace.

  Killing it would take this script down mid-install and could leave you with no
  damson at all. The build is already done and signed at:
      $APP

  Finish the install from a terminal that is NOT damson — Terminal.app or iTerm:
      cd "$REPO_ROOT" && ./scripts/install-local.sh
MSG
    exit 1
fi

# 3) Install — kill the running instance and replace it. Remove the quarantine bit
#    (usually absent for local builds, but if present it triggers a first-run Gatekeeper prompt).
echo "==> install to $DEST"
pkill -f "Damson.app/Contents/MacOS/damson" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> installed: $DEST  ($MARKETING_VERSION / $HASH)"

# 3b) Link damson-cli onto PATH. build-app.sh only drops it in Contents/Resources, so
#     without this `damson-cli` is not a command and nothing outside the app — a script, a
#     coordinator driving `spawn`/`watch-agents` — can reach the control socket at all.
#     Skipped rather than sudo-prompting if the target directory is not writable.
CLI_LINK_DIR="${CLI_LINK_DIR:-/usr/local/bin}"
for tool in damson-cli damson-crew; do
    SRC="$DEST/Contents/Resources/$tool"
    [[ -x "$SRC" ]] || continue
    if [[ -d "$CLI_LINK_DIR" && -w "$CLI_LINK_DIR" ]]; then
        ln -sf "$SRC" "$CLI_LINK_DIR/$tool"
        echo "==> linked $CLI_LINK_DIR/$tool -> $SRC"
    else
        echo "==> note: $CLI_LINK_DIR not writable; link it yourself:"
        echo "    sudo ln -sf \"$SRC\" $CLI_LINK_DIR/$tool"
    fi
done

# 4) Launch (can be skipped with NO_LAUNCH).
if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
    echo "==> launching"
    open -a "$DEST"
fi
