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
# Replace mapped executables atomically so rebuilding cannot truncate a running VM's helper.
HELPER_STAGING="$PWD/build/LumenQEMUHelper.next.dylib"
clang -dynamiclib -arch arm64 -O2 -framework AppKit -framework Foundation -o "$HELPER_STAGING" Sources/LumenHelper/LumenQEMUHelper.m Sources/LumenHelper/LumenDiskSync.c
codesign --force --sign - "$HELPER_STAGING"
mv -f "$HELPER_STAGING" "$APP/Contents/Resources/LumenQEMUHelper.dylib"
cp "$APP/Contents/Resources/LumenQEMUHelper.dylib" Resources/LumenQEMUHelper.dylib
cp .build/arm64-apple-macosx/release/Lumen "$APP/Contents/MacOS/Lumen.next"
mv -f "$APP/Contents/MacOS/Lumen.next" "$APP/Contents/MacOS/Lumen"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Raster logos for guests whose branding is not an SF Symbol (e.g. Abyss Linux).
mkdir -p "$APP/Contents/Resources/GuestLogos"
cp Resources/GuestLogos/*.png "$APP/Contents/Resources/GuestLogos/"
# Every distributable app includes the signed ARM64 driver packages.
# The preparation script fetches a compact subset of the pinned official ISO once.
if [ ! -f .runtime/WindowsDrivers.iso ]; then
  python3 scripts/prepare-windows-drivers.py
fi
cp .runtime/WindowsDrivers.iso "$APP/Contents/Resources/WindowsDrivers.iso"
python3 scripts/prepare-windows-clipboard.py
mkdir -p "$APP/Contents/Resources/WindowsClipboard"
cp .runtime/WindowsClipboard/* "$APP/Contents/Resources/WindowsClipboard/"
# Private folder sharing uses a loopback-only, per-VM authenticated service.
# Native wheels are pinned to CPython 3.14; Homebrew's python3 may be newer.
SHARING_PYTHON="${LUMEN_SHARING_PYTHON:-}"
if [ -z "$SHARING_PYTHON" ]; then
  for candidate in /opt/homebrew/opt/python@3.14/bin/python3.14 /opt/homebrew/bin/python3.14 /usr/local/bin/python3.14; do
    if [ -x "$candidate" ]; then SHARING_PYTHON="$candidate"; break; fi
  done
fi
if [ -z "$SHARING_PYTHON" ]; then
  echo "Windows sharing needs Python 3.14. Install python@3.14 or set LUMEN_SHARING_PYTHON." >&2
  exit 1
fi
"$SHARING_PYTHON" scripts/prepare-windows-sharing.py
mkdir -p "$APP/Contents/Resources/WindowsSharing"
cp -R .runtime/WindowsSharing/. "$APP/Contents/Resources/WindowsSharing/"
# Python runs with -B; omit build-machine bytecode from the sealed resources.
find "$APP/Contents/Resources/WindowsSharing" -type f -name '*.pyc' -delete
while IFS= read -r module; do
  codesign --force --sign - "$module"
done < <(find "$APP/Contents/Resources/WindowsSharing" -type f -name '*.so')
mkdir -p "$APP/Contents/Resources/Documentation"
cp docs/compatibility.md docs/feature-audit.md docs/windows-3d-integration.md "$APP/Contents/Resources/Documentation/"
# Hardened runtime; Lumen itself uses only Virtualization.framework. QEMU is a separate,
# separately entitled process, so this app needs no com.apple.security.hypervisor.
codesign --force --sign - --options runtime --entitlements Resources/Lumen.entitlements "$APP"
printf '\nBuilt %s\nOpen with: open "%s"\n' "$APP" "$APP"
