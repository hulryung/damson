#!/usr/bin/env bash
# build-dmg.sh — packages dist/Damson.app into a styled drag-to-Applications .dmg.
#
# Artifact: dist/Damson-<version>.dmg
#
# The installer window's look comes from three committed files:
#   Resources/dmg/background.tiff  the artwork  (scripts/gen-dmg-background.swift)
#   Resources/dmg/DS_Store         the Finder layout — window size, icon positions,
#                                  no toolbar  (scripts/make-dmg-layout.sh)
#   Resources/Damson.icns          the mounted volume's icon
# Replaying a recorded layout needs no Finder, so a release built on a headless CI
# runner looks exactly like one built here. hdiutil is the only tool required.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/dist/Damson.app"
DMG_RES="$REPO_ROOT/Resources/dmg"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found. Run scripts/build-app.sh (and sign-and-notarize.sh) first." >&2
    exit 1
fi

# Read the marketing version from Info.plist.
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"

DMG="$REPO_ROOT/dist/Damson-$VERSION.dmg"
# Fixed, version-free: the layout's background reference resolves by the volume's
# path, so the name has to be the same one make-dmg-layout.sh recorded against.
VOLNAME="Damson"
STAGE_DIR="$(mktemp -d -t damson-dmg-stage)"
RW_DMG="$(mktemp -u -t damson-dmg-rw).dmg"
MOUNT="$(mktemp -d -t damson-dmg-mnt)"
cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$STAGE_DIR" "$RW_DMG" "$MOUNT"
}
trap cleanup EXIT

echo "==> staging at $STAGE_DIR"
cp -R "$APP" "$STAGE_DIR/Damson.app"
# /Applications symlink — drag-to-install UX.
ln -s /Applications "$STAGE_DIR/Applications"
mkdir -p "$STAGE_DIR/.background"
cp "$DMG_RES/background.tiff" "$STAGE_DIR/.background/background.tiff"
cp "$REPO_ROOT/Resources/Damson.icns" "$STAGE_DIR/.VolumeIcon.icns"

rm -f "$DMG"
echo "==> hdiutil create (read-write, to dress the volume)"
hdiutil create -volname "$VOLNAME" \
    -srcfolder "$STAGE_DIR" \
    -fs HFS+ \
    -format UDRW \
    -ov "$RW_DMG" >/dev/null

# An explicit mount point keeps this off /Volumes, so a build cannot collide with a
# volume the user already has mounted, and -nobrowse keeps Finder out of it.
hdiutil attach "$RW_DMG" -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null

echo "==> applying the recorded window layout"
cp "$DMG_RES/DS_Store" "$MOUNT/.DS_Store"
# Tell Finder the volume has its own icon (the flag, not just the file).
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT" || echo "    warning: could not set the custom-icon flag"
fi
# Housekeeping the mount created; no reason to ship it.
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" "$MOUNT/.TemporaryItems" 2>/dev/null || true

sync
hdiutil detach "$MOUNT" -quiet
trap 'rm -rf "$STAGE_DIR" "$RW_DMG" "$MOUNT"' EXIT

echo "==> hdiutil convert (compressed, read-only)"
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG" >/dev/null

# If signed, codesigning the .dmg too is recommended. Proceeds if APPLE_SIGNING_IDENTITY is set.
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "==> codesign dmg"
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$DMG"
    # Submitting the .dmg separately to notarytool is recommended (Gatekeeper online check)
    if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
        echo "==> notarize dmg"
        NOTARY_ARGS=()
        if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
            NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        elif [[ -n "${APP_STORE_CONNECT_KEY_FILE:-}" && -n "${APP_STORE_CONNECT_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER:-}" ]]; then
            NOTARY_ARGS=(
                --key "$APP_STORE_CONNECT_KEY_FILE"
                --key-id "$APP_STORE_CONNECT_KEY_ID"
                --issuer "$APP_STORE_CONNECT_ISSUER"
            )
        elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
            NOTARY_ARGS=(
                --apple-id "$APPLE_ID"
                --password "$APPLE_APP_SPECIFIC_PASSWORD"
                --team-id "$APPLE_TEAM_ID"
            )
        fi
        if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
            xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
            xcrun stapler staple "$DMG"
            xcrun stapler validate "$DMG"
        fi
    fi
fi

echo ""
echo "==> $DMG"
ls -lh "$DMG"
