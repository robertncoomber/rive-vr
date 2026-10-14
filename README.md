# rive-vr

Spike: a Quest 3 OpenXR app where Rive draws every pixel. A thin C++ host (no draw calls) feeds head and controller poses into a `.riv` file, which renders both eyes with GPU Canvas.

Spec: https://claude.ai/code/artifact/c5ef94d6-6488-425d-8379-3d72055edfd0

## Layout

- `app/` Gradle module, manifest, CMake
- `src/` native host (OpenXR session, input, Rive host)
- `content/` exported `.riv` files
- `tools/` push/reload scripts
- `web-harness/` WebGL2 + GPU Canvas desktop test page (off-headset iteration)
- `third_party/rive-runtime/` pinned submodule

## Building rive-runtime for Android

```bash
cd third_party/rive-runtime/renderer
NDK_PATH=~/Library/Android/sdk/ndk/29.0.13113456 \
  ../build/build_rive.sh ninja android release \
  --with_rive_scripting --with_rive_canvas --with_rive_text --with_rive_layout
```

`--with_rive_canvas` compiles in RenderCanvas and the Ore GPU layer (GPU Canvas).
