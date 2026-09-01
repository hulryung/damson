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

# 2b) Notice when this shell is running inside the app being replaced.
#     Dogfooding means the maintainer's terminal usually IS the app under test, so this is
#     the normal case, not a corner one. Two things follow, both measured:
#
#     - `pkill` CANNOT kill it. pgrep/pkill skip the calling process *and its ancestors*
#       (BSD behaviour: `ps` lists this shell's parent zsh, `pgrep -x zsh` does not). So the
#       kill below is a silent no-op here, and without saying so the script would report
#       success while the user kept running the old build.
#     - It does not need to. The keeper runs a COPY of itself from the runtime dir precisely
#       so a cp-style install can swap the bundle underneath a live app (see
#       SessionHandoff). Damson → Restart Damson then comes up on the new binary, and with
#       "keep sessions on restart" every pane — including the terminal running this script —
#       survives the upgrade.
running_inside_target=false
ancestor_is_target() {
    local pid=$$ exe
    for _ in {1..24}; do
        exe="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        [[ "$exe" == "$DEST/Contents/MacOS/damson" ]] && return 0
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [[ -z "$pid" || "$pid" == "0" || "$pid" == "1" ]] && break
    done
    return 1
}
if ancestor_is_target; then
    running_inside_target=true
    echo "==> note: this shell runs inside $DEST"
    echo "    The bundle will be replaced under the live app; the running process keeps going"
    echo "    on the old one. Pick up the new build with Damson > Restart Damson."
fi

# 3) Install — kill the running instance and replace it. Remove the quarantine bit
#    (usually absent for local builds, but if present it triggers a first-run Gatekeeper prompt).
echo "==> install to $DEST"
# Kill only instances running THIS bundle, found by path rather than by pattern: the old
# `pkill -f Damson.app/...` also matched any other install (a dev copy, a second location),
# and could not see an ancestor at all.
if [[ "$running_inside_target" == "false" ]]; then
    ps -Ao pid=,comm= | while read -r pid exe; do
        [[ "$exe" == "$DEST/Contents/MacOS/damson" ]] && kill "$pid" 2>/dev/null || true
    done
    sleep 1
fi
# Move the old bundle aside rather than deleting it: when the app is running from $DEST —
# which is the dogfooding case — the live process still reads from its bundle (Sparkle,
# resources), and pulling those out from under it risks the very panes this is trying to
# preserve. The aside copy is removed once nothing is running from it.
ASIDE="$INSTALL_DIR/.Damson.app.replaced-$$"
if [[ -d "$DEST" ]]; then
    mv "$DEST" "$ASIDE"
fi
cp -R "$APP" "$DEST"
if [[ -d "$ASIDE" ]]; then
    if [[ "$running_inside_target" == "true" ]]; then
        echo "==> old bundle kept at $ASIDE while it is still running; remove it after the restart"
    else
        rm -rf "$ASIDE"
    fi
fi
# Sweep any aside copy left by an earlier run whose app has since been restarted.
for old_aside in "$INSTALL_DIR"/.Damson.app.replaced-*; do
    [[ -d "$old_aside" && "$old_aside" != "$ASIDE" ]] || continue
    if ! ps -Ao comm= | grep -qF "$old_aside/Contents/MacOS/damson"; then
        rm -rf "$old_aside"
    fi
done
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> installed: $DEST  ($MARKETING_VERSION / $HASH)"
if [[ "$running_inside_target" == "true" ]]; then
    echo "==> the old build is still running. To switch without losing your panes:"
    echo "    1. Settings > Terminal > turn on \"Keep sessions on restart\""
    echo "    2. Damson menu > Restart Damson"
fi

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
if [[ "${NO_LAUNCH:-0}" != "1" && "$running_inside_target" == "false" ]]; then
    echo "==> launching"
    open -a "$DEST"
fi
