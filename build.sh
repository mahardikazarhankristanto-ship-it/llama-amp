#!/bin/bash
# Builds Llama Amp.app with the Swift command-line tools (no Xcode project needed).
#   ./build.sh          release build: build/Llama Amp.app (stripped; symbols kept in build/LlamaAmp.dSYM)
#   DEV=1 ./build.sh    developer build with the test modes (--audiotest, --featuretest, --djtest, --perf …):
#                       build/dev/Llama Amp.app
set -euo pipefail
cd "$(dirname "$0")"
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14.0)
if [ "${DEV:-}" = 1 ]; then
  OUT=build/dev; EXTRA=(-D DEVTOOLS); WIDGET=()
else
  OUT=build; EXTRA=(-g -Xlinker -dead_strip); WIDGET=(-Xlinker -dead_strip)
fi
APP="$OUT/Llama Amp.app"

rm -rf "$APP" build/iconset build/makeicon
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

echo "• compiling"
swiftc "${FLAGS[@]}" "${EXTRA[@]}" Sources/*.swift -o "$APP/Contents/MacOS/LlamaAmp"

echo "• icon"
swiftc "${FLAGS[@]}" Tools/MakeIcon/main.swift Sources/PixelBuffer.swift Sources/Covers.swift -o build/makeicon
build/makeicon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP/Contents/Info.plist"

echo "• milkdrop"
# Butterchurn (MIT) and its preset packs, xz-compressed (2.2 MB → 0.3 MB); the app unpacks them as the page loads
MD="$APP/Contents/Resources/milkdrop"
mkdir -p "$MD"
cp Resources/milkdrop/milkdrop.html Resources/milkdrop/LICENSE-* "$MD/"
for f in Resources/milkdrop/*.min.js; do
  compression_tool -encode -a lzma -i "$f" -o "$MD/$(basename "$f").lzma"
done

echo "• widget"
WX="$APP/Contents/PlugIns/LlamaWidget.appex"
mkdir -p "$WX/Contents/MacOS"
swiftc "${FLAGS[@]}" ${WIDGET[@]+"${WIDGET[@]}"} -parse-as-library -application-extension Widget/LlamaWidget.swift -o "$WX/Contents/MacOS/LlamaWidget"
cp Widget/Info.plist "$WX/Contents/Info.plist"

if [ "${DEV:-}" != 1 ]; then
  echo "• stripping"
  # swiftc -g leaves the debug symbols beside the binary; keep them out of the app (for reading crash reports)
  rm -rf build/LlamaAmp.dSYM
  mv "$APP/Contents/MacOS/LlamaAmp.dSYM" build/LlamaAmp.dSYM
  strip -x "$APP/Contents/MacOS/LlamaAmp" "$WX/Contents/MacOS/LlamaWidget"
fi
codesign --force --sign - --entitlements Widget/Widget.entitlements "$WX"
codesign --force --sign - "$APP"
echo "• built $APP ($(du -sh "$APP" | cut -f1))"
