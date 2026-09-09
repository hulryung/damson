#!/usr/bin/env bash
# make-dmg-layout.sh — records the installer window's Finder layout into
# Resources/dmg/DS_Store, which build-dmg.sh then copies into every release.
#
# Run this only when the layout itself changes (window size, icon positions,
# background artwork size). It needs a logged-in GUI session because only Finder
# can write a .DS_Store; build-dmg.sh replays the result and needs no Finder, so
# releases still build on a headless CI runner.
#
# Usage: ./scripts/make-dmg-layout.sh      (dist/Damson.app must exist)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/dist/Damson.app"
BG="$REPO_ROOT/Resources/dmg/background.tiff"
OUT="$REPO_ROOT/Resources/dmg/DS_Store"

# Must match gen-dmg-background.swift and build-dmg.sh.
VOLNAME="Damson"
WIN_W=640; WIN_H=400          # content area, the size of the artwork
TITLEBAR=28                   # Finder counts the title bar in a window's bounds
ICON_SIZE=128
APP_X=168; APP_Y=214          # icon centres, from the top-left of the content area
APPS_X=472; APPS_Y=214

[[ -d "$APP" ]] || { echo "error: $APP not found. Run scripts/build-app.sh first." >&2; exit 1; }
[[ -f "$BG" ]] || { echo "error: $BG not found. Run swift scripts/gen-dmg-background.swift." >&2; exit 1; }

STAGE="$(mktemp -d -t damson-layout)"
TMP_DMG="$(mktemp -u -t damson-layout).dmg"
cleanup() {
    hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true
    rm -rf "$STAGE" "$TMP_DMG"
}
trap cleanup EXIT

echo "==> staging"
cp -R "$APP" "$STAGE/Damson.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.tiff"
# Staged only so the layout records a position for it; build-dmg.sh ships the real one.
cp "$REPO_ROOT/Resources/Damson.icns" "$STAGE/.VolumeIcon.icns"

echo "==> scratch image"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$TMP_DMG" >/dev/null
# Browsable on purpose: Finder has to open the window to write the layout.
hdiutil attach "$TMP_DMG" -noautoopen >/dev/null

echo "==> arranging the window in Finder"
osascript <<AS >/dev/null
tell application "Finder"
  set v to disk "$VOLNAME"
  open v
  set w to container window of v
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set pathbar visible of w to false
  set the bounds of w to {200, 120, 200 + $WIN_W, 120 + $WIN_H + $TITLEBAR}
  set opts to the icon view options of w
  set arrangement of opts to not arranged
  set icon size of opts to $ICON_SIZE
  set text size of opts to 13
  set label position of opts to bottom
  set shows item info of opts to false
  set background picture of opts to POSIX file "/Volumes/$VOLNAME/.background/background.tiff"
  set position of item "Damson.app" of v to {$APP_X, $APP_Y}
  set position of item "Applications" of v to {$APPS_X, $APPS_Y}
  -- Park the volume's housekeeping files outside the window: invisible to most
  -- people, but developers who switched hidden files on would otherwise find
  -- them sitting on top of the artwork.
  repeat with junk in {".background", ".VolumeIcon.icns", ".fseventsd", ".Trashes"}
    try
      set position of item junk of v to {900, 540}
    end try
  end repeat
  update v without registering applications
  delay 1
  close w
end tell
AS

# Finder writes .DS_Store when the window closes; give it a moment, then take it.
sleep 2
sync
cp "/Volumes/$VOLNAME/.DS_Store" "$OUT"
hdiutil detach "/Volumes/$VOLNAME" -quiet

echo "==> $OUT ($(stat -f%z "$OUT") bytes)"
echo "    commit it — build-dmg.sh replays this layout without Finder."
