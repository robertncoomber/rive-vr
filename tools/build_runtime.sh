#!/usr/bin/env bash
# Minimal playground runtime: GPU Canvas + scripting, no text/layout/decoders.
# Patches in tools/patches, applied here if missing:
#   size-opt.patch        --size_opt
#   ore-no-glfinish.patch drops a per-frame glFinish after Ore work
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
for PATCH in "$ROOT/tools/patches/size-opt.patch" \
             "$ROOT/tools/patches/ore-no-glfinish.patch"; do
  if ! git -C "$ROOT/third_party/rive-runtime" apply --reverse --check "$PATCH" 2>/dev/null; then
    git -C "$ROOT/third_party/rive-runtime" apply "$PATCH"
  fi
done
cd "$ROOT/third_party/rive-runtime/renderer"
# OPT=O2 (etc.) builds a speed variant into its own out dir; default is Oz.
OPT="${OPT:-Oz}"
RIVE_OUT=out/android_arm64_size
EXTRA=()
if [[ "$OPT" != Oz ]]; then
  RIVE_OUT="out/android_arm64_$OPT"
  EXTRA=(--opt_level="$OPT")
fi
RIVE_PREMAKE_ARGS='' RIVE_OUT="$RIVE_OUT" \
NDK_PATH="$SDK/ndk/27.2.12479018" \
  ../build/build_rive.sh ninja android release \
  --with_rive_scripting --with_rive_canvas --no-rive-decoders --size_opt ${EXTRA[@]+"${EXTRA[@]}"} \
  -- librive.a librive_pls_renderer.a libluau_vm.a
