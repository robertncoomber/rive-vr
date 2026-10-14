#!/usr/bin/env bash
# Pushes a .riv to the headset as the scene the host loads, then restarts it.
# Usage: tools/push.sh [path/to/file.riv]   (default: content/scene.riv)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIV="${1:-$ROOT/content/scene.riv}"
PKG=so.fluid.rivevr
DEST="/sdcard/Android/data/$PKG/files"

adb shell mkdir -p "$DEST"
adb push "$RIV" "$DEST/scene.riv" >/dev/null
adb shell am force-stop "$PKG"
adb shell am start -n "$PKG/android.app.NativeActivity" >/dev/null
echo "Pushed $(basename "$RIV") and restarted $PKG"
