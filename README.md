# Rive VR

A small, standalone Meta Quest playground built to explore **Rive as a VR
rendering and gameplay runtime**. The current APK is **1.37 MB**, including
the scene.

## What we're doing

A thin C++ OpenXR host handles headset/controller tracking and local
networking. It passes poses into a Rive ViewModel; a Luau script handles
movement, collisions, scene geometry, and stereo rendering through Rive's
GPU Canvas. Rive produces both eye images, which the host submits to OpenXR.

The playground includes:

- Gorilla Tag style movement: push against surfaces with your hands to move,
  jump, and climb.
- Trees, branches, decks, practice steps, and a grid-lined central court.
- Multiplayer over the same Wi-Fi network, with interpolated head/hand poses
  and small fallback name plates.

## Why we're doing it

We're testing how much of a responsive VR experience can live inside a
`.riv` file, with a small native host and fast iteration in Rive.

Keeping the download tiny is part of the experiment. Materials are
procedural, name plates use a small vector pixel font, and the build omits
unused text, layout, and image-decoding features. Static linking, symbol
stripping, and compression keep the APK compact. The scene is bundled, so
there are no extra asset downloads or servers to set up.

This is an experimental playground, not a complete game engine.

## Build and run

The scripts currently target macOS with the Android SDK/NDK, JDK, Ninja,
Python 3, and an Android debug signing key installed. The Rive runtime
checkout must be present in `third_party/rive-runtime`.

```bash
bash tools/fetch_openxr.sh
bash tools/build_apk.sh
adb install -r build/rivevr.apk
adb shell am start -n so.fluid.rivevr/android.app.NativeActivity
```

The first build compiles the minimal, size-optimized Rive runtime (applying
`tools/patches/size-opt.patch` to `third_party/rive-runtime` if needed). OpenXR
goes through `src/xr_loader.cpp` instead of the Khronos loader; only the
headers from `tools/fetch_openxr.sh` are used. With `advzip` installed
(`brew install advancecomp`) the APK is recompressed with zopfli.

## Edit the scene

- `content/scripts/VRScene.luau` — level, locomotion, players, and rendering.
- `content/shaders/scene_lit.wgsl` — procedural materials and name plates.
- `src/` — OpenXR host and LAN multiplayer.

Sync source changes into the open Rive document with `tools/rive_mcp.py`,
export using `bash tools/export_riv.sh`, then rebuild the APK.
`bash tools/push.sh` supports faster scene-only iteration on a connected
headset by enabling an external scene override.
