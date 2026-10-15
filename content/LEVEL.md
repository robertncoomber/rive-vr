# Grove playground

The level is authored in `scripts/VRScene.luau`; its GPU material is in
`shaders/scene_lit.wgsl`. The runtime export is `scene.riv`.

Spawn opens onto the central grid court, which stays open for movement
and social space. The right route climbs five 45 cm steps; the
left route uses a stump, tree branches and two decks joined by a beam.
Seven trees frame the court. Rock walls enclose a roughly 30 m square.
All trunks, branches, platforms and walls use the existing box collision
system. Canopies are decorative. Movement tuning and multiplayer are unchanged.

Grass, bark, leaves, stone and plank patterns are procedural in the shader.
There are no bitmap environment textures. Fine pattern contrast fades with
screen-space derivatives to limit shimmer. The plaza and practice steps
retain the prototype grid treatment.

## Player name plates

Remote players get small upright plates 23 cm above their head centres.
The plates are 40 x 8.5 cm and face the viewer. They use the same session-ID
index as the avatar colour to select Moss, Fern, Pebble, Maple, Willow,
Birch, Cedar or Sprout consistently across peers. Names may repeat and can
change when a player starts a new session. Plates are hidden beyond 10 m
and inside 35 cm to avoid crowding the view.

The lettering is geometry built once from a tiny pixel font: one quad per
run of lit font pixels, drawn just in front of a dark plate, so it stays
sharp at any distance and needs no font, image or texture. (Earlier plates
were drawn into canvas textures, which showed only their clear colour on
Quest.) This is fallback naming only; Meta account access is not enabled.

## Player skins

Players are skinned by the Skin artboard (512 x 256): the left half is the
face, the right half a fur tile. VRScene instances it once per remote slot
and once for our own arms, draws each into a `context:canvas` every frame,
and the lit shader samples it: the face onto the face plate (mode 12), the
fur box-projected onto head, torso and arms at 3.3 tiles per metre (mode 13).
The Skin view model carries `fur` (player colour), `lookX`/`lookY` (pupils
follow the viewer) and `mouth` (opens with head speed). Its state machine
runs Blink and Breathe (spots) on separate layers. Restyle the artboard
freely; keep those view model property names.

Canvas textures do work on Quest. The earlier blank name plates were most
likely text, which this runtime omits.

Editor quirks found on the way: an artboard used by a script artboard input
is only exported when it is a Component (`isComponent`); otherwise the input
silently resolves to nil on device and `init` never runs. View models created
over MCP get no list order and stay invisible to scripts, so Skin reuses the
file's former empty `ViewModel1`.

## Standalone build

`bash tools/build_apk.sh` produces `build/rivevr.apk`, signed with the local
Android debug key. It embeds only `content/scene.riv`; installation requires
no separately pushed content. The screen, pedestal, sample playback, and
sample project files have been removed.

The runtime is built in a separate `android_arm64_minimal` output with GPU
Canvas and Luau scripting. Text shaping, layout and image decoding are
excluded. Name plates are geometry and procedural materials need no image
decoders. Native libraries are stripped for shipping, exported symbols
are limited to the Android entry point, and the APK uses maximum ZIP
compression. Debug symbols remain in `build/cmake/libmain.so`.

OpenXR 1.1.63 is built from official Khronos SDK source with `-Oz` and LTO,
then statically linked into the app. This removes the separate loader shared
library and lets the linker discard unused code and merge runtime code.
Android packed relocations/RELR reduce native metadata (minimum API is 32).
Exception handling remains enabled in the loader as recommended upstream.
`tools/build_openxr.sh` downloads and builds the matching source on first use.

For scene iteration, `bash tools/push.sh` enables the explicit external scene
override. Return to the packaged scene with
`adb shell setprop debug.rivevr.external_scene 0`, then restart the app.

## Validation

Script/shader diagnostics, native build, APK signature, packaged scene byte
comparison and export-symbol checks passed. The standalone APK was installed
on Quest 2 and loaded its embedded scene. The user confirmed the playground
renders as intended with the screen and pedestal removed.

Measured APK size: 1,368,566 bytes (1.37 MB / 1.31 MiB), including the scene.
This is 23.6% smaller than the previous 1,790,557-byte standalone build.
The static-loader APK's signature, embedded scene, sole native entry point,
system-only native dependencies and Quest 2 OpenXR/scene startup were checked.
The prior APK was 4,743,794 bytes and required separate content files.
