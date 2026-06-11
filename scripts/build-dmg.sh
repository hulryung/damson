#!/usr/bin/env bash
# build-dmg.sh — packages dist/Damson.app into a drag-to-Applications .dmg.
#
# Artifact: dist/Damson-<version>.dmg
#
# Uses hdiutil only (no additional tool dependencies). For a nicer result, you can
# swap in `create-dmg` (brew install create-dmg).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/dist/Damson.app"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found. Run scripts/build-app.sh (and sign-and-notarize.sh) first." >&2
    exit 1
fi

# Read the marketing version from Info.plist.
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"

DMG="$REPO_ROOT/dist/Damson-$VERSION.dmg"
STAGE_DIR="$(mktemp -d -t damson-dmg-stage)"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "==> staging at $STAGE_DIR"
cp -R "$APP" "$STAGE_DIR/Damson.app"
# /Applications symlink — drag-to-install UX.
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG"
echo "==> hdiutil create"
hdiutil create -volname "Damson $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG"

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
