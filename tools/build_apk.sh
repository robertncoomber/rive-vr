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

# OPT=O2 bash tools/build_apk.sh builds a speed-optimized variant in build-O2/.
export OPT="${OPT:-Oz}"
OUT="$ROOT/build"
RIVE_OUT="$ROOT/third_party/rive-runtime/renderer/out/android_arm64_size"
if [[ "$OPT" != Oz ]]; then
  OUT="$ROOT/build-$OPT"
  RIVE_OUT="$ROOT/third_party/rive-runtime/renderer/out/android_arm64_$OPT"
fi
mkdir -p "$OUT/apk/lib/arm64-v8a" "$OUT/assets"
if [[ ! -f "$RIVE_OUT/librive.a" ]]; then
  bash "$ROOT/tools/build_runtime.sh"
fi

"$CMAKE" -S "$ROOT/app" -B "$OUT/cmake" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-32 \
  -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" \
  -DOPT_LEVEL="$OPT" -DRIVE_OUT="$RIVE_OUT" >/dev/null
"$CMAKE" --build "$OUT/cmake"

cp "$OUT/cmake/libmain.so" "$OUT/apk/lib/arm64-v8a/"
# Keep symbols in build/cmake/libmain.so for debugging, strip only shipped copies.
STRIP="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
"$STRIP" --strip-all "$OUT/apk/lib/arm64-v8a/libmain.so"
cp "$ROOT/content/scene.riv" "$OUT/assets/scene.riv"

rm -f "$OUT/unaligned.apk" "$OUT/rivevr.apk"
"$BUILD_TOOLS/aapt2" link -o "$OUT/unaligned.apk" \
  --manifest "$ROOT/app/AndroidManifest.xml" -I "$PLATFORM" -A "$OUT/assets"
(cd "$OUT/apk" && zip -9 -q "$OUT/unaligned.apk" \
  lib/arm64-v8a/libmain.so)
# Zopfli recompression (brew install advancecomp) saves ~4%. It also deflates
# resources.arsc, which must stay stored on API 30+, so put that back as-is.
if command -v advzip >/dev/null; then
  advzip -z -4 -i 15 -q "$OUT/unaligned.apk"
  rm -rf "$OUT/arsc" && mkdir -p "$OUT/arsc"
  unzip -q "$OUT/unaligned.apk" resources.arsc -d "$OUT/arsc"
  zip -q -d "$OUT/unaligned.apk" resources.arsc
  (cd "$OUT/arsc" && zip -q -0 "$OUT/unaligned.apk" resources.arsc)
fi
"$BUILD_TOOLS/zipalign" -f -P 16 4 "$OUT/unaligned.apk" "$OUT/rivevr.apk"
"$BUILD_TOOLS/apksigner" sign --ks "$HOME/.android/debug.keystore" \
  --ks-pass pass:android --key-pass pass:android "$OUT/rivevr.apk"
echo "Built $OUT/rivevr.apk"
