#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build --disable-sandbox --build-system native --product Lumen -c release --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
APP="$PWD/build/Lumen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" Resources
clang -dynamiclib -arch arm64 -O2 -framework AppKit -framework Foundation -o "$APP/Contents/Resources/LumenQEMUHelper.dylib" Sources/LumenHelper/LumenQEMUHelper.m
cp "$APP/Contents/Resources/LumenQEMUHelper.dylib" Resources/LumenQEMUHelper.dylib
cp .build/arm64-apple-macosx/release/Lumen "$APP/Contents/MacOS/Lumen"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --entitlements Resources/Lumen.entitlements "$APP"
printf '\nBuilt %s\nOpen with: open "%s"\n' "$APP" "$APP"
