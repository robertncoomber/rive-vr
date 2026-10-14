#!/usr/bin/env bash
# Builds app/ into a signed debug APK without Gradle: CMake for libmain.so,
# aapt2 for the manifest, then zipalign + apksigner.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="$SDK/ndk/27.2.12479018"
BUILD_TOOLS="$SDK/build-tools/35.0.0"
PLATFORM="$SDK/platforms/android-32/android.jar"
CMAKE="$SDK/cmake/3.22.1/bin/cmake"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home}"

OUT="$ROOT/build"
mkdir -p "$OUT/apk/lib/arm64-v8a"

"$CMAKE" -S "$ROOT/app" -B "$OUT/cmake" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-32 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" >/dev/null
"$CMAKE" --build "$OUT/cmake"

cp "$OUT/cmake/libmain.so" "$OUT/apk/lib/arm64-v8a/"
cp "$ROOT/third_party/openxr/aar/prefab/modules/openxr_loader/libs/android.arm64-v8a/libopenxr_loader.so" \
  "$OUT/apk/lib/arm64-v8a/"

rm -f "$OUT/unaligned.apk" "$OUT/rivevr.apk"
"$BUILD_TOOLS/aapt2" link -o "$OUT/unaligned.apk" \
  --manifest "$ROOT/app/AndroidManifest.xml" -I "$PLATFORM"
(cd "$OUT/apk" && zip -q -r "$OUT/unaligned.apk" lib)
"$BUILD_TOOLS/zipalign" -f -P 16 4 "$OUT/unaligned.apk" "$OUT/rivevr.apk"
"$BUILD_TOOLS/apksigner" sign --ks "$HOME/.android/debug.keystore" \
  --ks-pass pass:android --key-pass pass:android "$OUT/rivevr.apk"
echo "Built $OUT/rivevr.apk"
