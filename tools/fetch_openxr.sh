#!/usr/bin/env bash
# Downloads the Khronos OpenXR loader for Android (headers + arm64 .so) from
# Maven Central into third_party/openxr/aar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.1.63}"
DEST="$ROOT/third_party/openxr"
AAR="openxr_loader_for_android-$VERSION.aar"

mkdir -p "$DEST"
curl -sfL -o "$DEST/$AAR" \
  "https://repo1.maven.org/maven2/org/khronos/openxr/openxr_loader_for_android/$VERSION/$AAR"
rm -rf "$DEST/aar"
unzip -q "$DEST/$AAR" -d "$DEST/aar"
echo "OpenXR loader $VERSION in $DEST/aar"
