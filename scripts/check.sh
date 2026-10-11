#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export LUMEN_TEST_ROOT="$PWD/.build/test-tmp"
mkdir -p "$LUMEN_TEST_ROOT"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift test --disable-sandbox --build-system native --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
