# Working on rive-vr

Notes for agents and humans changing this repo: how a frame works, how to
build and iterate, the headset knobs, and what we learned about performance.
The README is the short overview.

## How a frame works

`src/main.cpp` is a NativeActivity OpenXR host (GLES 3.2, one swapchain
holding both eyes side by side). Per frame:

1. `xrWaitFrame` / `xrBeginFrame`.
2. Eye poses + FOV, controller grip/aim poses, triggers and remote players
   are written into the XR ViewModel (`writeEyePoses`, `writeControllers`,
   `writeRemotePlayers`). A/B buttons are handled here too.
3. `recordRive`: the state machine advances (Luau `advance` in
   `VRScene.luau`) and the artboard draws into Rive's deferred session.
4. `replayRive`: the recording replays into the acquired swapchain image.
   With `direct=1` the script's GPU passes (Ore) render straight into it.
5. `xrEndFrame` with a projection layer using the poses the script drew with.

The script does everything visible: level geometry, locomotion, monkes,
title, the refresh-rate readout, and both eyes' rendering through GPU Canvas
with `content/shaders/scene_lit.wgsl`.

## Build

- `bash tools/build_apk.sh` builds into `build/` (`-Oz`). `OPT=O2` builds a
  speed variant into `build-O2/` (it measured no faster).
- The Rive runtime (`third_party/rive-runtime`) is built by
  `tools/build_runtime.sh`, which first applies `tools/patches/*.patch`:
  - `size-opt.patch`: `--size_opt` premake option.
  - `ore-no-glfinish.patch`: removes a `glFinish()` in
    `RenderContextGLImpl::scrubStateAfterOre()` (see Performance).
  Patches are applied to the submodule's working tree, never committed there.
  Incremental runtime rebuilds take seconds.
- `src/xr_loader.*` replaces the Khronos loader. Any new OpenXR core function
  must be added to the `X(...)` list in `xr_loader.hpp`. Extension functions
  go through `xrGetInstanceProcAddr`.
- `app/exports.map` trims exported symbols; `advzip` recompresses the APK.

## Scene workflow

The `.riv` is authored in the Rive desktop editor (file "VR"), driven through
its local MCP server on port 9791.

1. Edit `content/scripts/VRScene.luau` (or the shader) in the repo.
2. `python3 tools/rive_mcp.py sync scene/VRScene content/scripts/VRScene.luau`
   pushes it into the editor and prints diagnostics (`[]` = clean).
3. `bash tools/export_riv.sh` writes `content/scene.riv`.
4. Rebuild the APK (bundles the scene), or `bash tools/push.sh` for a
   scene-only push (sets `debug.rivevr.external_scene=1`; clear it to go back
   to the bundled scene).

Editor quirks that fail silently on device:

- An artboard used by a script `Input<Artboard<...>>` is only exported if it
  is a Component (`iscomponent`).
- View models created via MCP never show up to scripts; add properties to an
  existing view model instead.

Prefer script-only features that need no new ViewModel properties. The
refresh-rate readout, for example, derives Hz from `advance`'s `dt` (the host
computes it from OpenXR display times).

## Headset properties

All read at startup unless noted. Set with `adb shell setprop`, clear with
`adb shell "setprop debug.rivevr.<name> ''"`, then restart the app.

| Property | Default | Meaning |
|---|---|---|
| `debug.rivevr.hz` | 90 | Refresh rate. Live: applied within 1 s. |
| `debug.rivevr.ffr` | 3 | Foveation 0 off, 1 low, 2 medium, 3 high. Live. |
| `debug.rivevr.scale` | 1.0 | Eye resolution x recommended. Needs restart. |
| `debug.rivevr.direct` | 0 | 1 = script renders straight into the swapchain. |
| `debug.rivevr.msaa` | 4 | Sample count for the scene passes. |
| `debug.rivevr.srgb` | 1 | sRGB swapchain. |
| `debug.rivevr.cpulevel` / `gpulevel` | 2 | `XR_EXT_performance_settings` level 0-3. |
| `debug.rivevr.external_scene` | 0 | Load `scene.riv` pushed by `tools/push.sh`. |

Recommended: `direct=1 msaa=1 srgb=1`. Quest 3: `scale=1.2, hz=207` or
`scale=1.4, hz=185`. Quest 2: `scale=1.0, hz=120`. (`tools/setup_headset.sh`
still sets `scale=1.8`, from before 90 Hz+.)

In headset: right controller **A** steps through the rates this headset
supports, **B** toggles foveation off/high. Both buzz; a rate change shows the
new Hz in front of you for 3 s. A later change to the property takes over again.

## Refresh rates

`XR_FB_display_refresh_rate` lists 72/80/90/120 on Quest 3, yet Horizon OS
2.7+ accepts any rate up to 207 Hz if asked directly (off-spec, Meta-specific).
`loadRefreshRates` adds 144/165/185/207 only when `ro.product.model` is
exactly `Quest 3` (not 3S, not Quest 2) and falls back to the highest listed
rate if a request fails. 240 Hz additionally needs developer mode plus
`debug.oculus.forceDisplayScaling` (untested). Thermal events can drop the
system to 72 Hz.

## Performance

Measured 2026-10-14. The app is GPU-bound; CPU is ~2 ms/frame.

- **The old "rive cpu" ~10 ms was a GPU wait.** The runtime called `glFinish()`
  after every Ore frame. Ore and Rive share one GL context, so GL ordering
  already covers it; removing it let CPU and GPU overlap and ended the dips at
  120 Hz. -O2 vs -Oz made no difference for the same reason.
- **Foveation** (`XR_FB_foveation`) cut app GPU time ~23% (Quest 2, scale 1.4:
  9.3 -> 7.2 ms). Applying `GL_QCOM_texture_foveated` to the swapchain
  ourselves did nothing (the runtime owns swapchain foveation); use the XR
  extension.
- **GPU time scales with pixels**: Quest 2 at 120 Hz was ~1.2 ms + 4.2 ms x
  scale^2. Quest 3 with foveation: 207 Hz holds at scale 1.2 (3.2 ms), 185 Hz
  at 1.4.
- Next levers: render the 2048^2 sun shadow map once for the static level
  (it redraws the whole level every frame), cheaper fragment work in
  `scene_lit.wgsl`, less overdraw.

### Measuring

- Our log, once a second: `adb logcat -s 'RiveVR:*'` (quote the pattern in
  zsh). `fps=... rive cpu=...` plus `phases ms/frame:` with
  wait/in/adv/rec/acq/rep/end and GPU replay time from timer queries (which
  reads ~2.5 ms under the true app GPU time).
- Ground truth for GPU: `adb logcat -s 'VrApi:*' | grep FPS=` gives `App=`
  (app GPU ms), `GPU%`, `Fov=`, clocks, `Stale=` and temperature.
- CPU profile: NDK `simpleperf/app_profiler.py -p so.fluid.rivevr` with
  `-r "-e cpu-clock -f 4000 -g --trace-offcpu --duration 5"` and
  `-lib` pointing at the unstripped `build/cmake/libmain.so`. Use
  `--trace-offcpu`: blocking waits are invisible otherwise.
- `adb exec-out screencap` returns black for the VR view; ask a human to look.
- A sleeping headset or a Guardian dialog stops frames (no `fps=` lines);
  `adb shell input keyevent KEYCODE_WAKEUP` wakes it, Guardian needs a human.
