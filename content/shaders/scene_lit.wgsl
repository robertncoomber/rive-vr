// One shader for the whole MVP scene: Lambert-lit solids, or a procedural
// grid when params.x > 0.5 (the floor). The sun casts shadows through a
// depth map rendered from its direction (vsShadow) once per frame.
struct U {
  viewProj: mat4x4<f32>,
  model: mat4x4<f32>,
  color: vec4<f32>,
  params: vec4<f32>,
  light: mat4x4<f32>, // world to sun clip space
};

@group(0) @binding(0) var<uniform> u: U;
@group(1) @binding(0) var shadowMap: texture_depth_2d;
@group(1) @binding(1) var shadowSampler: sampler_comparison;
@group(1) @binding(2) var skin: texture_2d<f32>; // this player's Skin artboard
@group(1) @binding(3) var skinSampler: sampler;

const SUN = vec3<f32>(0.4, 1.0, 0.3);

struct VOut {
  @builtin(position) pos: vec4<f32>,
  @location(0) world: vec3<f32>,
  @location(1) normal: vec3<f32>,
  @location(2) local: vec3<f32>,
  @location(3) @interpolate(flat) color: vec3<f32>,
  @location(4) @interpolate(flat) mode: f32,
};

@vertex
fn vs(@location(0) p: vec3<f32>, @location(1) n: vec3<f32>) -> VOut {
  let w = u.model * vec4<f32>(p, 1.0);
  var o: VOut;
  o.pos = u.viewProj * w;
  o.world = w.xyz;
  o.local = p;
  o.normal = (u.model * vec4<f32>(n, 0.0)).xyz;
  o.color = u.color.rgb;
  o.mode = u.params.x;
  return o;
}

// The static level, baked once into one world-space mesh whose vertices
// carry their own colour and material; drawn in a single call.
@vertex
fn vsLevel(@location(0) p: vec3<f32>, @location(1) n: vec3<f32>,
           @location(2) c: vec3<f32>, @location(3) m: f32) -> VOut {
  var o: VOut;
  o.pos = u.viewProj * vec4<f32>(p, 1.0);
  o.world = p;
  o.local = p;
  o.normal = n;
  o.color = c;
  o.mode = m;
  return o;
}

// Depth-only passes from the sun: posed parts, then the baked level.
@vertex
fn vsShadow(@location(0) p: vec3<f32>, @location(1) n: vec3<f32>) -> @builtin(position) vec4<f32> {
  return u.light * u.model * vec4<f32>(p, 1.0);
}

@vertex
fn vsShadowLevel(@location(0) p: vec3<f32>, @location(1) n: vec3<f32>,
                 @location(2) c: vec3<f32>, @location(3) m: f32) -> @builtin(position) vec4<f32> {
  return u.light * vec4<f32>(p, 1.0);
}

// 1 lit, 0 shadowed. Four bilinear compare taps give a soft 3x3 texel edge.
// Offsetting along the normal keeps surfaces from shadowing themselves.
fn sunlight(world: vec3<f32>, n: vec3<f32>) -> f32 {
  let c = u.light * vec4<f32>(world + n * 0.04, 1.0);
  let uv = vec2<f32>(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
  let texel = 1.0 / vec2<f32>(textureDimensions(shadowMap));
  let depth = c.z - 0.0004;
  var lit = 0.0;
  lit += textureSampleCompareLevel(shadowMap, shadowSampler, uv + vec2<f32>(-0.75, -0.75) * texel, depth);
  lit += textureSampleCompareLevel(shadowMap, shadowSampler, uv + vec2<f32>(0.75, -0.75) * texel, depth);
  lit += textureSampleCompareLevel(shadowMap, shadowSampler, uv + vec2<f32>(-0.75, 0.75) * texel, depth);
  lit += textureSampleCompareLevel(shadowMap, shadowSampler, uv + vec2<f32>(0.75, 0.75) * texel, depth);
  let inside = all(uv > vec2<f32>(0.0)) && all(uv < vec2<f32>(1.0)) && c.z < 1.0;
  return select(1.0, lit * 0.25, inside);
}

// Player skins come from the Skin artboard, drawn each frame for each
// player: its left half is the face, its right half a fur tile wrapped
// around every body part. Mode 12 is the face plate, 13 the fur.
const FUR_TILES = 3.3; // fur tiles per metre
fn skinColour(local: vec3<f32>, mode: f32) -> vec3<f32> {
  if mode < 12.5 {
    // Front (-Z) of the plate. It is 1.27x wider than tall, so the square
    // face is cropped top and bottom to keep the eyes round. The plate's thin
    // edges take plain skin from the face's corner.
    let face = vec2<f32>(0.5 - local.x, 0.5 - local.y / 1.27);
    let uv = select(vec2<f32>(0.02, 0.98), face, local.z < -0.45);
    return textureSampleLevel(skin, skinSampler, vec2<f32>(uv.x * 0.5, uv.y), 0.0).rgb;
  }
  // Each box face is projected onto its own plane, in metres (the model's
  // scale), so spots stay one size on every part.
  let size = vec3<f32>(length(u.model[0].xyz), length(u.model[1].xyz), length(u.model[2].xyz));
  let p = local * size * FUR_TILES;
  let a = abs(local);
  var q = p.xy;
  if a.x >= a.y && a.x >= a.z {
    q = p.zy;
  } else if a.y >= a.z {
    q = p.xz;
  }
  // Inset from the tile edge so filtering never reaches the face half.
  let t = clamp(fract(q), vec2<f32>(0.004), vec2<f32>(0.996));
  return textureSampleLevel(skin, skinSampler, vec2<f32>(0.5 + 0.5 * t.x, t.y), 0.0).rgb;
}

// World-space, pixel-like patterns: no image assets or texture downloads.
fn grain(p: vec3<f32>) -> f32 {
  return fract(sin(dot(p, vec3<f32>(12.9898, 78.233, 37.719))) * 43758.5453);
}
@fragment
fn fs(i: VOut) -> @location(0) vec4<f32> {
  let n = normalize(i.normal);
  let mode = i.mode;
  let fw = max(fwidth(i.world.xz), vec2<f32>(0.0001));
  let cell = abs(fract(i.world.xz - 0.5) - 0.5) / fw;
  let line = 1.0 - min(min(cell.x, cell.y), 1.0);
  var base = i.color;
  let noise = grain(floor(i.world * 12.0));
  // Suppress fine pattern contrast at a distance to reduce VR shimmer.
  let detail = 1.0 - smoothstep(0.025, 0.15, length(fwidth(i.world)));
  if mode > 2.5 && mode < 7.5 {
    var variation = (noise - 0.5) * 0.16;
    if mode > 3.5 && mode < 4.5 {
      let bark = grain(floor(i.world * vec3<f32>(18.0, 1.8, 18.0)));
      variation = (bark - 0.5) * 0.30;
    }
    if mode > 6.5 {
      let seam = step(0.94, fract(i.world.z * 4.0));
      variation = (noise - 0.5) * 0.1 - seam * 0.15;
    }
    base += vec3<f32>(variation * detail);
  }
  if mode > 11.5 {
    // Skinned player parts: the colour is a shade (arms darken toward the hand).
    base = skinColour(i.local, mode) * i.color;
  }
  let ndl = max(dot(n, normalize(SUN)), 0.0);
  let sun = select(0.0, sunlight(i.world, n), ndl > 0.0);
  var shaded = base * (0.55 + 0.45 * ndl * sun);
  if mode > 0.5 && mode < 1.5 {
    shaded = mix(shaded, vec3<f32>(0.49, 0.72, 0.70), line * 0.48);
  }
  if mode > 1.5 && mode < 2.5 { return vec4<f32>(base, 1.0); }
  let fog = smoothstep(18.0, 48.0, length(i.world.xz));
  return vec4<f32>(mix(shaded, vec3<f32>(0.53, 0.67, 0.68), fog * 0.55), 1.0);
}
