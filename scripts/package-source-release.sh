#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
tag="${1:-v$version}"
if [ "$tag" != "v$version" ]; then
  echo "Release tag must match the app version: v$version" >&2
  exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo 'Commit the reviewed source before packaging a release.' >&2
  exit 1
fi
if [ "$(git rev-parse "$tag^{commit}")" != "$(git rev-parse HEAD)" ]; then
  echo 'Release tag must point to the current commit.' >&2
  exit 1
fi

output="$PWD/build/releases/$tag"
archive="LumensVM-$tag-source.zip"
mkdir -p "$output"
git archive --format=zip --prefix="LumensVM-$version/" --output="$output/$archive" "$tag"
cd "$output"
shasum -a 256 "$archive" > SHA256SUMS
printf 'Source release prepared: %s\n' "$output"
