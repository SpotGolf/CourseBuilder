#!/bin/bash
#
# Build a drag-and-drop DMG: the app on the left, an arrow, and an Applications link on the right.
#
# Usage: scripts/make-dmg.sh <path/to/App.app> <output.dmg>
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <path/to/App.app> <output.dmg>" >&2
  exit 1
fi

APP_PATH="$1"
DMG_PATH="$2"
APP_NAME="$(basename "$APP_PATH" .app)"
VOLUME_NAME="$APP_NAME"

WINDOW_WIDTH=600
WINDOW_HEIGHT=400
ICON_SIZE=128
APP_X=150
APPS_X=450
ICON_Y=190
ARROW_START_X=$((APP_X + ICON_SIZE / 2 + 16))
ARROW_END_X=$((APPS_X - ICON_SIZE / 2 - 16))

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORK_DIR="$(mktemp -d)"
STAGING="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/rw.dmg"
MOUNT_POINT=""
cleanup() {
  if [ -n "$MOUNT_POINT" ]; then hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true; fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 1. Stage the app, the Applications link, and the hidden background image.
mkdir -p "$STAGING/.background"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
swift "$SCRIPT_DIR/make-dmg-background.swift" "$STAGING/.background/background.png" \
  "$WINDOW_WIDTH" "$WINDOW_HEIGHT" "$ARROW_START_X" "$ARROW_END_X" "$ICON_Y"

# 2. Create a writable image and mount it.
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDRW -fs HFS+ "$RW_DMG" >/dev/null
# Mount under /Volumes so Finder can see the disk by name.
MOUNT_POINT="$(hdiutil attach "$RW_DMG" -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
if [ -z "$MOUNT_POINT" ]; then echo "failed to mount $RW_DMG" >&2; exit 1; fi
VOLUME_NAME="$(basename "$MOUNT_POINT")"

# 3. Lay out the Finder window and store it in .DS_Store.
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, $((100 + WINDOW_WIDTH)), $((100 + WINDOW_HEIGHT))}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 14
    set background picture of opts to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {$APP_X, $ICON_Y}
    set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

# 4. Compress into the final read-only image.
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
echo "Created $DMG_PATH"
