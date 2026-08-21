#!/bin/bash
#
# filename: make-dmg.sh
# path: scripts/make-dmg.sh
# purpose: Builds Entanglo in Release and packages it into a
#          drag-to-Applications .dmg with a styled window:
#          - dark gradient background (generated PNG)
#          - hidden sidebar/toolbar, 640x440 window
#          - large icons, app left, Applications right, arrow between
#          - README hidden offscreen (still on disk, just not visible)
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="${ENTANGLO_VERSION:-0.1.0}"
SCHEME="Entanglo"
CONFIG="Release"
PROJECT="Entanglo.xcodeproj"

DIST="$ROOT/dist"
BUILD="$ROOT/build/release"
STAGE="$ROOT/build/dmg-stage"
TMPDMG="$ROOT/build/Entanglo-$VERSION.rw.dmg"
DMG="$DIST/Entanglo-$VERSION.dmg"
VOLNAME="Entanglo $VERSION"
BG_SCRIPT="$ROOT/scripts/make-dmg-background.swift"

echo "==> Cleaning previous artifacts"
rm -rf "$BUILD" "$STAGE" "$DMG" "$TMPDMG"
mkdir -p "$DIST" "$BUILD" "$STAGE/.background"

echo "==> Building $SCHEME ($CONFIG)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD/derived" \
  CODE_SIGN_IDENTITY="Entanglo Local Signing" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  OTHER_CODE_SIGN_FLAGS="--options=runtime" \
  build \
  | grep -E "^(/.*error:|/.*warning:|\*\* BUILD|note:)" || true

APP="$BUILD/derived/Build/Products/$CONFIG/Entanglo.app"
if [ ! -d "$APP" ]; then
  echo "ERROR: Entanglo.app not found at $APP" >&2
  exit 1
fi

echo "==> Staging .dmg contents"
cp -R "$APP" "$STAGE/Entanglo.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<EOF
Entanglo $VERSION

To install: drag Entanglo.app into the Applications folder.

First launch: macOS may block the app because it is ad-hoc signed.
Right-click Entanglo in Applications and choose "Open", then confirm.

Required permissions (System Settings):
  - Accessibility           (needed for input sharing)
  - Input Monitoring        (needed for input capture)

Entanglo discovers other Macs on your local network via Bonjour
(_entanglo._tcp). Approve "Allow local network access" when prompted.

More info & support: https://entanglo.pages.dev
EOF

echo "==> Generating window background"
swift "$BG_SCRIPT" "$STAGE/.background/background.png"

echo "==> Building writable .dmg"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$TMPDMG" >/dev/null

echo "==> Mounting to apply Finder layout"
MOUNT_DIR="/Volumes/$VOLNAME"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
hdiutil attach "$TMPDMG" -nobrowse -noautoopen -mountpoint "$MOUNT_DIR" >/dev/null
sleep 1

# AppleScript: hide toolbar/sidebar, set size, icon view, background, positions.
# Y coordinates in Finder are top-down. Icon centers we want:
#   Entanglo.app  → (180, 240)
#   Applications  → (460, 240)
#   README.txt    → (700, 700)   (offscreen, hidden)
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 120, 840, 560}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Entanglo.app" of container window to {180, 240}
        set position of item "Applications" of container window to {460, 240}
        try
            set position of item "README.txt" of container window to {700, 700}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Hide the .background folder and other dotfiles from the Finder view
chflags hidden "$MOUNT_DIR/.background" 2>/dev/null || true

sync
sleep 1

echo "==> Unmounting"
hdiutil detach "$MOUNT_DIR" >/dev/null

echo "==> Compressing final .dmg"
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMPDMG"

SIZE=$(du -h "$DMG" | awk '{print $1}')
echo
echo "==> Done."
echo "    DMG:     $DMG"
echo "    Size:    $SIZE"
echo "    Volume:  $VOLNAME"
echo
echo "Open with: open \"$DMG\""
echo "Copy to imac2 with: scp \"$DMG\" imac2:~/Downloads/"
