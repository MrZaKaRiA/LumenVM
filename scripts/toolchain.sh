# Shared toolchain setup for build.sh and check.sh. Source it; do not execute it.
#
# Prefers a full Xcode when one is installed. On a Command Line Tools-only Mac, newer
# macOS SDKs declare SwiftUI's @State (and friends) as macros implemented by the
# SwiftUIMacros compiler plugin, which ships only with Xcode. When that plugin is
# missing and SDKROOT is unset, fall back to the newest installed CLT SDK that still
# declares @State as a plain property wrapper.

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

lumen_developer_dir() {
  if [ -n "${DEVELOPER_DIR:-}" ]; then
    printf '%s\n' "$DEVELOPER_DIR"
  else
    xcode-select -p 2>/dev/null || true
  fi
}

lumen_is_command_line_tools() {
  case "$(lumen_developer_dir)" in
    */CommandLineTools|*/CommandLineTools/) return 0 ;;
    *) return 1 ;;
  esac
}

# True when the SDK's SwiftUI declares @State as an external SwiftUIMacros macro.
lumen_sdk_needs_swiftui_macros() {
  local iface
  for iface in \
    "$1/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface" \
    "$1/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface"; do
    if [ -f "$iface" ] && grep -q 'module: "SwiftUIMacros", type: "StateMacro"' "$iface"; then
      return 0
    fi
  done
  return 1
}

lumen_has_swiftui_macros_plugin() {
  local dev
  dev="$(lumen_developer_dir)"
  [ -n "$(find "$dev/usr/lib/swift/host/plugins" "$dev/usr/local/lib/swift/host/plugins" \
    -maxdepth 1 -name 'libSwiftUIMacros*' 2>/dev/null | head -1)" ]
}

lumen_select_sdk() {
  [ -z "${SDKROOT:-}" ] || return 0
  lumen_is_command_line_tools || return 0
  local dev default_sdk candidate
  dev="$(lumen_developer_dir)"
  default_sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  [ -n "$default_sdk" ] || return 0
  default_sdk="$(cd -P "$default_sdk" && pwd)"
  lumen_sdk_needs_swiftui_macros "$default_sdk" || return 0
  lumen_has_swiftui_macros_plugin && return 0
  # Newest versioned SDK first; skip symlinks (MacOSX26.sdk -> MacOSX26.5.sdk).
  while IFS= read -r candidate; do
    candidate="$dev/SDKs/$candidate"
    [ -L "$candidate" ] && continue
    if ! lumen_sdk_needs_swiftui_macros "$candidate"; then
      export SDKROOT="$candidate"
      printf 'note: %s needs the SwiftUIMacros plugin, which only Xcode ships.\n' "$(basename "$default_sdk")" >&2
      printf 'note: Command Line Tools only; building with %s instead (set SDKROOT to override).\n' "$(basename "$candidate")" >&2
      return 0
    fi
  done < <(cd "$dev/SDKs" 2>/dev/null && ls -d MacOSX[0-9]*.sdk | sort -V -r)
  printf 'error: %s needs the SwiftUIMacros plugin, which only Xcode ships, and no older\n' "$(basename "$default_sdk")" >&2
  printf 'error: Command Line Tools SDK is installed. Install Xcode or set SDKROOT.\n' >&2
  return 1
}

# XCTest ships with Xcode; recent Command Line Tools do not include it.
lumen_has_xctest() {
  local dev
  dev="$(lumen_developer_dir)"
  [ -d "$dev/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ] ||
    [ -d "$dev/Library/Developer/Frameworks/XCTest.framework" ] ||
    [ -d "$dev/Library/Frameworks/XCTest.framework" ]
}
