#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
lumen_select_sdk
export LUMEN_TEST_ROOT="$PWD/.build/test-tmp"
mkdir -p "$LUMEN_TEST_ROOT"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
tests_status=0
if lumen_test_flags; then
  swift test --disable-sandbox --build-system native --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" ${LUMEN_TEST_FLAGS[@]+"${LUMEN_TEST_FLAGS[@]}"} || tests_status=$?
else
  echo "error: Swift Testing is not available: Testing.framework not found in $(lumen_developer_dir)." >&2
  echo "error: Install Xcode or recent Command Line Tools, or set DEVELOPER_DIR." >&2
  echo "Skipping swift test; still running the display-drawing check." >&2
  tests_status=1
fi
mkdir -p build
clang -framework Foundation -framework CoreGraphics scripts/test-display-drawing.m -o build/test-display-drawing
build/test-display-drawing
exit "$tests_status"
