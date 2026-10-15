#!/usr/bin/env bash
# Size-optimized static OpenXR loader, from the matching official SDK release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="$SDK/ndk/27.2.12479018"
CMAKE="$SDK/cmake/3.22.1/bin/cmake"
SOURCE="$ROOT/third_party/openxr/sdk"
if [[ ! -f "$SOURCE/CMakeLists.txt" ]]; then
  git clone --depth 1 --branch release-1.1.63 \
    https://github.com/KhronosGroup/OpenXR-SDK.git "$SOURCE"
fi
"$CMAKE" -S "$SOURCE" -B "$ROOT/build/openxr-static" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-32 \
  -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" \
  -DDYNAMIC_LOADER=OFF -DBUILD_WITH_SYSTEM_JSONCPP=OFF \
  -DBUILD_API_LAYERS=OFF -DBUILD_TESTS=OFF -DBUILD_CONFORMANCE_TESTS=OFF \
  '-DCMAKE_C_FLAGS_MINSIZEREL=-Oz -DNDEBUG -flto -ffunction-sections -fdata-sections' \
  '-DCMAKE_CXX_FLAGS_MINSIZEREL=-Oz -DNDEBUG -flto -ffunction-sections -fdata-sections'
"$CMAKE" --build "$ROOT/build/openxr-static" --target openxr_loader --parallel
