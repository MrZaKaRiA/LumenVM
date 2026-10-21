#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-$PWD/build/Lumen.app}"
failed=0

check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'BLOCK %s\n' "$label"
        failed=1
    fi
}

check 'App bundle exists' test -d "$app"
if [ -d "$app" ]; then
    check 'Sealed app resources and nested code' codesign --verify --deep --strict "$app"
    signature="$(codesign -dv "$app" 2>&1 || true)"
    if [[ "$signature" == *'Signature=adhoc'* ]]; then
        printf 'BLOCK Developer ID signature and notarization (current build is ad hoc)\n'
        failed=1
    else
        check 'Gatekeeper assessment' spctl --assess --type execute "$app"
    fi
    if [ -x "$app/Contents/Resources/qemu-system-aarch64" ]; then
        printf 'PASS  Bundled QEMU runtime\n'
    else
        printf 'BLOCK Bundled QEMU runtime (Windows currently needs Homebrew QEMU)\n'
        failed=1
    fi
    if [ -x "$app/Contents/Resources/python3.14" ]; then
        printf 'PASS  Bundled Windows sharing runtime\n'
    else
        printf 'BLOCK Bundled Windows sharing runtime (currently needs Homebrew Python)\n'
        failed=1
    fi
fi
printf 'INFO  Windows graphics: 2D VirtIO display; no integrated Direct3D guest/host stack.\n'
printf 'INFO  Full Windows installation, automatic graphics handoff, and other guest acceptance still require validation.\n'
exit "$failed"
