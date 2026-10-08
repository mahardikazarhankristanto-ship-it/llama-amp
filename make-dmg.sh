#!/bin/bash
# make-dmg.sh: builds the universal release and packs it into build/Llama-Amp-<version>.dmg
# (the app, a shortcut to Applications to drag it onto, and a note on opening an app from outside the App Store).
set -euo pipefail
cd "$(dirname "$0")"
UNIVERSAL=1 ./build.sh
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="build/Llama Amp.app"
DMG="build/Llama-Amp-$VER.dmg"
RW=build/dmg-rw.dmg
MNT=build/dmg-mount

echo "• disk image"
rm -f "$RW" "$DMG"
hdiutil detach "$MNT" -quiet 2>/dev/null || true
hdiutil create -size 40m -fs HFS+ -volname "Llama Amp" -ov "$RW" -quiet
hdiutil attach "$RW" -nobrowse -noautoopen -mountpoint "$MNT" -quiet
ditto "$APP" "$MNT/Llama Amp.app"
ln -s /Applications "$MNT/Applications"
cat > "$MNT/If macOS won't open it.txt" <<'TXT'
Installing Llama Amp
====================

1. Drag "Llama Amp" onto the Applications folder in this window.
2. Open it from Applications (or Launchpad).


If macOS says it can't verify the developer
-------------------------------------------

Llama Amp is free and open source. It isn't signed with a paid Apple Developer ID,
so the first time you open it macOS shows a warning. To allow it once:

  macOS 15 Sequoia and later:
    1. Open Llama Amp and click "Done" on the warning.
    2. Open System Settings > Privacy & Security.
    3. Scroll down to "Llama Amp was blocked..." and click "Open Anyway".
    4. Click "Open Anyway" again and confirm with your password or Touch ID.

  macOS 14 Sonoma:
    Right-click (or Control-click) Llama Amp in Applications, choose "Open",
    then click "Open" in the dialog.

  Or, in Terminal (any version):
    xattr -dr com.apple.quarantine "/Applications/Llama Amp.app"

After that it opens normally.


Requirements: macOS 14 Sonoma or later, Apple silicon or Intel.
Source code, help and updates: https://github.com/mahardikazarhankristanto-ship-it/llama-amp
TXT
# the disk shows the llama icon
cp "$APP/Contents/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
SetFile -c icnC "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"
rm -rf "$MNT/.fseventsd"
hdiutil detach "$MNT" -quiet
hdiutil convert "$RW" -format ULFO -o "$DMG" -quiet
rm -f "$RW"
echo "• $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
