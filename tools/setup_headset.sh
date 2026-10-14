#!/usr/bin/env bash
# Installs the app on the connected headset, applies the recommended render
# settings and pushes the scene. Usage: tools/setup_headset.sh [adb serial]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ge 1 ]]; then
  export ANDROID_SERIAL="$1"
fi

adb install -r "$ROOT/build/rivevr.apk" >/dev/null
# Direct-to-swapchain path, 1.8x resolution, no MSAA (see the perf commit).
adb shell setprop debug.rivevr.direct 1
adb shell setprop debug.rivevr.msaa 1
adb shell setprop debug.rivevr.srgb 1
adb shell setprop debug.rivevr.scale 1.8
"$ROOT/tools/push.sh" "$ROOT/content/scene.riv"
echo "Set up $(adb shell getprop ro.product.model | tr -d '\r') ($(adb get-serialno))"
