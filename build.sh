#!/bin/bash
# Builds Llama Amp.app with the Swift command-line tools (no Xcode project needed).
#   ./build.sh               release build: build/Llama Amp.app (stripped; symbols kept in build/*.dSYM)
#   UNIVERSAL=1 ./build.sh   the same for Apple silicon and Intel Macs (what make-dmg.sh ships)
#   WIDGET=1 ./build.sh      also bundle the WidgetKit widget (macOS only runs it when the app is signed with an
#                            Apple developer certificate; the app's own desktop player needs no signing)
#   DEV=1 ./build.sh         developer build with the test modes (--audiotest, --featuretest, --djtest, --perf …):
#                            build/dev/Llama Amp.app
set -euo pipefail
cd "$(dirname "$0")"
ARCHS=(arm64)
[ "${UNIVERSAL:-}" = 1 ] && ARCHS=(arm64 x86_64)
if [ "${DEV:-}" = 1 ]; then
  OUT=build/dev; EXTRA=(-D DEVTOOLS); WIDGETFLAGS=()
else
  OUT=build; EXTRA=(-g -Xlinker -dead_strip); WIDGETFLAGS=(-Xlinker -dead_strip)
fi
APP="$OUT/Llama Amp.app"
OBJ=build/obj

# compile <output> <swiftc arguments…>: one binary per architecture, joined with lipo
compile() {
  local out=$1; shift
  local parts=()
  for a in "${ARCHS[@]}"; do
    local o="$OBJ/$a-$(basename "$out")"
    swiftc -O -swift-version 5 -target "$a-apple-macos14.0" "$@" -o "$o"
    parts+=("$o")
  done
  lipo -create "${parts[@]}" -output "$out"
}

rm -rf "$APP" build/iconset build/makeicon "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

echo "• compiling (${ARCHS[*]})"
compile "$APP/Contents/MacOS/LlamaAmp" "${EXTRA[@]}" Sources/*.swift Shared/*.swift

echo "• icon"
swiftc -O -swift-version 5 Tools/MakeIcon/main.swift Sources/PixelBuffer.swift Sources/Covers.swift -o build/makeicon
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

WX="$APP/Contents/PlugIns/LlamaWidget.appex"
if [ "${WIDGET:-}" = 1 ]; then
  echo "• widget"
  mkdir -p "$WX/Contents/MacOS"
  compile "$WX/Contents/MacOS/LlamaWidget" ${WIDGETFLAGS[@]+"${WIDGETFLAGS[@]}"} -parse-as-library -application-extension Widget/LlamaWidget.swift Shared/*.swift
  cp Widget/Info.plist "$WX/Contents/Info.plist"
fi

if [ "${DEV:-}" != 1 ]; then
  echo "• stripping"
  # swiftc -g leaves the debug symbols beside each binary in build/obj; keep them (for reading crash reports)
  for d in "$OBJ"/*-LlamaAmp.dSYM; do rm -rf "build/$(basename "$d")"; mv "$d" build/; done
  strip -x "$APP/Contents/MacOS/LlamaAmp"
  [ -d "$WX" ] && strip -x "$WX/Contents/MacOS/LlamaWidget"
fi
[ -d "$WX" ] && codesign --force --sign - --entitlements Widget/Widget.entitlements "$WX"
codesign --force --sign - "$APP"
echo "• built $APP ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/LlamaAmp"))"
