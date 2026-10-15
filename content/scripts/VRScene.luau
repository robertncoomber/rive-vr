-- VRScene: a Gorilla Tag style playground rendered entirely by Rive. The
-- native host writes eye poses, controller poses and triggers into the XR
-- ViewModel; this script moves the body (see locomotion), then renders the
-- level and our arms once per eye.
--
-- Two output paths, chosen by the host through the XR ViewModel:
--  - canvas (direct = 0): each eye renders into its own gpuCanvas, then both
--    are composited side by side into the 2W x H artboard.
--  - direct (direct = 1): one pass renders both eyes (a viewport each) and
--    resolves straight into the host's swapchain via context:gpuTarget().
--    GL can only wrap the target top-down, so the projection is flipped in Y
--    (and culling flipped with it) to land upright in OpenXR's bottom-up image.
-- msaa (1, 2 or 4) sets the sample count for both paths.

local DEFAULT_SAMPLES = 4
local DEPTH_FORMAT: DepthFormat = 'depth24plus-stencil8'
local NEAR = 0.05
local FAR = 100
local UBO_SIZE = 224 -- mat4 viewProj, mat4 model, vec4 color, vec4 params, mat4 light

-- Sun shadows: one depth map from the light, shared by both eyes. SUN points
-- towards the light and matches scene_lit.wgsl. The map is fitted to the
-- walled level (SHADOW_BOUNDS: min x, y, z, max x, y, z), about 2 cm a texel.
local SHADOW_SIZE = 2048
local SHADOW_FORMAT: DepthFormat = 'depth32float'
local SUN = { 0.4, 1.0, 0.3 }
local SHADOW_BOUNDS = { -17.5, -0.5, -17.5, 17.5, 9.5, 17.5 }


type Eye = {
  canvas: GPUCanvas?,          -- canvas path only
  msaaView: GPUTextureView?,   -- canvas path only, nil when msaa = 1
  depthView: GPUTextureView?,  -- canvas path only
  ubos: { GPUBuffer },
  groups: { GPUBindGroup },
}

type Obj = {
  mesh: string, -- 'cube' | 'floor'
  x: number, y: number, z: number, -- centre
  sx: number, sy: number, sz: number, -- size (floor: half extents)
  r: number, g: number, b: number,
  material: number?,
  decorative: boolean?,
}

-- A playground to climb and jump around on: steps, towers, pillars, a back
-- wall and a floating bridge. Boxes are axis aligned, so they double as
-- colliders. box(x, z, w, h, d) stands on the floor; base lifts it.
local function box(x: number, z: number, w: number, h: number, d: number,
                   r: number, g: number, b: number, base: number?): Obj
  local y0 = base or 0
  return { mesh = 'cube', x = x, y = y0 + h / 2, z = z, sx = w, sy = h, sz = d, r = r, g = g, b = b }
end

-- Grove: a clear social plaza framed by two progressively higher routes.
-- Materials: 0 solid, 1 prototype grid, 2 emissive, 3 grass, 4 bark,
-- 5 leaves, 6 rock, 7 timber; players use 12 skin face, 13 skin fur.
-- No bitmap texture assets.
local OBJECTS: { Obj } = {
  { mesh = 'floor', x = 0, y = 0, z = 0, sx = 18, sy = 1, sz = 18,
    r = 0.29, g = 0.39, b = 0.23, material = 3 },
}
local function add(x: number, z: number, w: number, h: number, d: number,
                   base: number, r: number, g: number, b: number, mat: number,
                   decorative: boolean?)
  local o = box(x, z, w, h, d, r, g, b, base)
  o.material = mat
  o.decorative = decorative
  table.insert(OBJECTS, o)
end
-- Flush-looking raised grid court; generous space around the spawn.
add(0, -3, 8, 0.12, 12, 0, 0.15, 0.22, 0.25, 1)
-- Low practice route to the right, rising in reachable 45 cm increments.
for i = 1, 5 do
  add(4.7 + (if i > 3 then -0.8 else 0), -1 - i * 1.65,
      1.6, 0.45 * i, 1.5, 0, 0.48, 0.56, 0.53, 1)
end
-- Chunky trunks and broad branches: every visible woody surface collides.
local function tree(x: number, z: number, height: number, side: number)
  add(x, z, 0.85, height, 0.85, 0, 0.38, 0.25, 0.15, 4)
  add(x, z, 1.3, 0.35, 1.3, 0, 0.34, 0.24, 0.14, 4)
  add(x + side * 0.85, z, 2.3, 0.28, 0.65, 1.05, 0.49, 0.33, 0.19, 4)
  add(x, z - 0.8, 0.7, 0.3, 2.25, 2.0, 0.49, 0.33, 0.19, 4)
  add(x - side * 0.75, z, 2.2, 0.32, 0.8, 3.0, 0.49, 0.33, 0.19, 4)
  -- Canopy is visual only; it does not trap the player in invisible corners.
  add(x, z, 3.8, 1.5, 3.5, height - 0.3, 0.22, 0.39, 0.21, 5, true)
  add(x + 0.3, z, 2.5, 1.0, 2.6, height + 1.2, 0.32, 0.48, 0.25, 5, true)
end
tree(-5.4, -2.5, 5.0, 1)
tree(-6.4, -6.2, 5.8, 1)
tree(-4.8, -10.0, 6.1, -1)
tree(6.5, -5.0, 5.6, -1)
tree(7.0, -10.2, 6.3, -1)
tree(-8.5, 3.0, 5.4, 1)
tree(7.5, 3.4, 5.0, -1)
-- Tree decks and a broad beam link, with a low access stump.
add(-3.9, -1.5, 1.3, 0.5, 1.3, 0, 0.5, 0.35, 0.21, 4)
add(-6.4, -6.2, 3.1, 0.25, 2.8, 2.65, 0.59, 0.43, 0.27, 7)
add(-5.6, -8.2, 0.85, 0.22, 3.4, 2.65, 0.62, 0.46, 0.28, 7)
add(-4.8, -10.0, 3.0, 0.25, 2.6, 2.65, 0.59, 0.43, 0.27, 7)
-- Two seating / launch ledges leave the main sightline open.
add(-2.5, -7.6, 2.0, 0.42, 0.65, 0, 0.58, 0.43, 0.27, 7)
add(2.5, -7.6, 2.0, 0.42, 0.65, 0, 0.58, 0.43, 0.27, 7)
-- Continuous rock boundary; uneven cap heights break up the silhouette.
for i = -2, 2 do
  local h = 4.5 + (i % 3) * 0.8
  add(i * 6, -16, 6.1, h, 2, 0, 0.38, 0.44, 0.42, 6)
  add(i * 6, 16, 6.1, h, 2, 0, 0.38, 0.44, 0.42, 6)
  add(-16, i * 6, 2, h, 6.1, 0, 0.36, 0.42, 0.40, 6)
  add(16, i * 6, 2, h, 6.1, 0, 0.36, 0.42, 0.40, 6)
end
local LEVEL_DRAWS = 1 -- the whole static level, baked into one mesh
local ARM_PARTS = 3 -- per hand: our upper arm, forearm, hand (see monke)
local CONTROLLER_DRAWS = 2 * ARM_PARTS

-- Multiplayer: the host broadcasts our head and hands on the local network
-- and writes up to REMOTE_SLOTS other players (already interpolated) into
-- the XR ViewModel. Each is drawn as a box monke (see monke) and a name plate.
local REMOTE_SLOTS = 4
local SKIN_W, SKIN_H = 512, 256 -- Skin artboard: face left, fur tile right
local SELF_SKIN = REMOTE_SLOTS + 1 -- our own arms
-- Skin expressions: pupil travel in skin px, mouth height in skin px from
-- rest to fully open (at SKIN_MOUTH_SPEED m/s of head speed), easing rate.
local SKIN_LOOK = 15
local SKIN_MOUTH_REST = 14
local SKIN_MOUTH_OPEN = 46
local SKIN_MOUTH_SPEED = 3
local SKIN_EASE = 10 -- 1/s
local MONKE_PARTS = 10 -- head, face, torso, belly, 2 x (upper arm, forearm, hand)
local REMOTE_DRAWS = MONKE_PARTS + 2 -- + name plate and its lettering
local TITLE_BASE = LEVEL_DRAWS + CONTROLLER_DRAWS + REMOTE_SLOTS * REMOTE_DRAWS
local PLAYER_COLOURS: { { number } } = {
  { 0.95, 0.45, 0.25 }, { 0.3, 0.75, 0.95 }, { 0.6, 0.9, 0.35 }, { 0.95, 0.8, 0.25 },
  { 0.85, 0.4, 0.85 }, { 0.35, 0.9, 0.75 }, { 0.95, 0.55, 0.6 }, { 0.6, 0.6, 0.95 },
}
local HUD_COLOUR: { number } = { 0.96, 0.95, 0.88 }
-- Stable fallback names use the same id-derived index as avatar colours.
local PLAYER_NAMES: { string } = { 'MOSS', 'FERN', 'PEBBLE', 'MAPLE', 'WILLOW', 'BIRCH', 'CEDAR', 'SPROUT' }
-- A tiny pixel font, drawn as geometry, keeps the prototype style and adds
-- no font asset.
local GLYPHS: { [string]: { number } } = {
  A = {14,17,17,31,17,17,17}, B = {30,17,17,30,17,17,30},
  C = {14,17,16,16,16,17,14}, D = {30,17,17,17,17,17,30},
  E = {31,16,16,30,16,16,31}, F = {31,16,16,30,16,16,16},
  G = {14,17,16,23,17,17,15}, V = {17,17,17,17,17,10,4},
  H = {17,17,17,31,17,17,17}, I = {31,4,4,4,4,4,31},
  L = {16,16,16,16,16,16,31}, M = {17,27,21,21,17,17,17},
  N = {17,25,21,19,17,17,17}, O = {14,17,17,17,17,17,14},
  P = {30,17,17,30,16,16,16}, R = {30,17,17,30,20,18,17},
  S = {15,16,16,14,1,1,30}, T = {31,4,4,4,4,4,4},
  U = {17,17,17,17,17,17,14}, W = {17,17,17,21,21,21,10},
  ['0'] = {14,17,19,21,25,17,14}, ['1'] = {4,12,4,4,4,4,14},
  ['2'] = {14,17,1,2,4,8,31}, ['3'] = {31,2,4,2,1,17,14},
  ['4'] = {2,6,10,18,31,2,2}, ['5'] = {31,16,30,1,1,17,14},
  ['6'] = {6,8,16,30,17,17,14}, ['7'] = {31,1,2,4,8,8,8},
  ['8'] = {14,17,17,14,17,17,14}, ['9'] = {14,17,17,15,1,2,12},
}
local POSE_KEYS: { string } = { 'px', 'py', 'pz', 'qx', 'qy', 'qz', 'qw' }

type Hand = { touching: boolean, ready: boolean, x: number, y: number, z: number }

type Part = { model: { number }, r: number, g: number, b: number, mode: number }
-- A remote player's posed monke. key is the colour index of the player in
-- the slot (-1 when empty); a change means a new player, so the yaw snaps.
type Monke = { key: number, yaw: number, x: number, y: number, z: number, parts: { Part } }

-- Each player's skin is an instance of the Skin artboard drawn into its own
-- canvas every frame (blinking, breathing fur), with its view model driven
-- from gameplay: fur colour, where the eyes look and how open the mouth is.
type Skin = {
  vm: Data.Skin?,
  instance: Artboard<Data.Skin>?,
  canvas: Canvas,
  group: GPUBindGroup?, -- group 1: the shadow map and this skin
  lookX: number, lookY: number, mouth: number, -- eased towards their targets
  hx: number, hy: number, hz: number,          -- last head position, for speed
  active: boolean,                             -- drawn this frame
}

-- A title letter: its mesh, its place along the line and its colour.
type TitleLetter = { verts: GPUBuffer, count: number, index: number, colour: { number } }

type VRScene = {
  nameVerts: { GPUBuffer },    -- lettering per PLAYER_NAMES entry
  nameCounts: { number },      -- vertex count of each
  props: { [string]: Property<number> },
  eyes: { Eye },
  litShader: Shader?,
  config: string,               -- current w/h/samples/path, rebuild on change
  samples: number,
  direct: boolean,
  directMsaa: GPUTextureView?,  -- direct path: 2W x H, nil when msaa = 1
  directDepth: GPUTextureView?,
  warnedNoTarget: boolean,
  pipeline: GPUPipeline?,       -- posed parts
  levelPipeline: GPUPipeline?,  -- the baked level
  shadowPipeline: GPUPipeline?,
  levelShadowPipeline: GPUPipeline?,
  drawLayout: GPUBindGroupLayout?,   -- group 0: per-draw uniforms
  shadowLayout: GPUBindGroupLayout?, -- group 1: shadow map and sampler
  shadowView: GPUTextureView?,
  shadowGroup: GPUBindGroup?,     -- for everything without a skin
  skinArtboard: Input<Artboard<Data.Skin>>,
  skins: { Skin },
  titleLetters: { TitleLetter },
  titleTime: number,            -- s since the title was placed, -1 before
  titleX: number, titleY: number, titleZ: number, titleYaw: number,
  titleParts: { Part },         -- this frame's letters, in titleLetters order
  titleShown: { number },       -- which of them are visible
  hudDigits: { TitleLetter },   -- refresh rate readout glyphs, '0'..'9'
  rateCandidate: number,        -- Hz the last frames ran at (from dt)
  rateRun: number,              -- consecutive frames at rateCandidate
  rateShown: number,            -- settled Hz, 0 before the first
  hudTime: number,              -- s since the readout appeared, -1 hidden
  hudParts: { Part },           -- this frame's digits, left to right
  hudShown: { number },         -- hudDigits index of each of hudParts                -- one per remote slot, then ours (SELF_SKIN)
  shadowPassGroup: GPUBindGroup?, -- placeholder group 1 while the map renders
  lightViewProj: { number },
  cubeVerts: GPUBuffer?,
  levelVerts: GPUBuffer?,
  levelCount: number,
  sampler: ImageSampler?,
  context: Context?,
  width: number,
  height: number,
  staging: buffer,
  -- Locomotion: the rig is where the play space sits in the world.
  rigX: number, rigY: number, rigZ: number,
  rigYaw: number,   -- turns the play space so we start facing down the court
  aligned: boolean, -- rig set from the first tracked head pose
  velX: number, velY: number, velZ: number,
  hands: { Hand },
  history: { { number } }, -- recent body velocities: vx, vy, vz
  monkes: { Monke },
  selfYaw: number?,       -- our own torso yaw, nil until the first pose
  selfArms: { { Part }? }, -- our own arms by hand, nil while untracked
}

local PROP_NAMES: { string } = { 'eyeWidth', 'eyeHeight', 'frameIndex', 'seenFrame', 'msaa', 'direct' }
for _, eye in { 'eyeL', 'eyeR' } do
  for _, k in { 'px', 'py', 'pz', 'qx', 'qy', 'qz', 'qw', 'fovL', 'fovR', 'fovU', 'fovD' } do
    table.insert(PROP_NAMES, eye .. '_' .. k)
  end
end
for _, hand in { 'L', 'R' } do
  for _, pose in { 'grip', 'aim' } do
    for _, k in { 'px', 'py', 'pz', 'qx', 'qy', 'qz', 'qw' } do
      table.insert(PROP_NAMES, pose .. hand .. '_' .. k)
    end
  end
  table.insert(PROP_NAMES, 'trigger' .. hand)
  table.insert(PROP_NAMES, 'active' .. hand)
end
for _, part in { 'netHead', 'netHandL', 'netHandR' } do
  for _, k in POSE_KEYS do
    table.insert(PROP_NAMES, part .. '_' .. k)
  end
end
table.insert(PROP_NAMES, 'netColor')
for slot = 1, REMOTE_SLOTS do
  table.insert(PROP_NAMES, 'p' .. slot .. '_active')
  table.insert(PROP_NAMES, 'p' .. slot .. '_color')
  for _, part in { 'head', 'handL', 'handR' } do
    for _, k in POSE_KEYS do
      table.insert(PROP_NAMES, 'p' .. slot .. '_' .. part .. '_' .. k)
    end
  end
end

-- ---------------------------------------------------------------- geometry

local function push(t: { number }, ...: number)
  for _, v in { ... } do
    table.insert(t, v)
  end
end

local function cubeData(): { number }
  local t: { number } = {}
  local faces: { { number } } = {
    { 1, 0, 0,   1, -1, -1,  1, 1, -1,  1, 1, 1,  1, -1, 1 },
    { -1, 0, 0, -1, -1, 1,  -1, 1, 1,  -1, 1, -1, -1, -1, -1 },
    { 0, 1, 0,  -1, 1, -1,  -1, 1, 1,   1, 1, 1,   1, 1, -1 },
    { 0, -1, 0, -1, -1, 1,  -1, -1, -1, 1, -1, -1, 1, -1, 1 },
    { 0, 0, 1,  -1, -1, 1,   1, -1, 1,  1, 1, 1,  -1, 1, 1 },
    { 0, 0, -1,  1, -1, -1, -1, -1, -1, -1, 1, -1, 1, 1, -1 },
  }
  for _, f in faces do
    for _, i in { 0, 1, 2, 0, 2, 3 } do
      push(t, f[4 + i * 3] * 0.5, f[5 + i * 3] * 0.5, f[6 + i * 3] * 0.5, f[1], f[2], f[3])
    end
  end
  return t
end

local function floorData(): { number }
  local t: { number } = {}
  push(t, -1, 0, -1, 0, 1, 0,  -1, 0, 1, 0, 1, 0,  1, 0, 1, 0, 1, 0)
  push(t, -1, 0, -1, 0, 1, 0,  1, 0, 1, 0, 1, 0,  1, 0, -1, 0, 1, 0)
  return t
end

-- Name plate lettering as geometry: the pixel font laid out on a 128 x 32
-- grid (3 px font pixels), one quad per run of lit pixels in a row, in the
-- plate's local space (the unit cube) just in front of its +Z face. Not a
-- context:canvas() texture: on Quest those sampled as their clear colour
-- alone. Geometry also stays sharp at any distance.
local NAME_Z = 0.75 -- in front of the face at 0.5 (plate depth is 4 mm)
local function nameData(name: string): { number }
  local t: { number } = {}
  local left = (128 - (#name * 6 - 1) * 3) / 2
  local function quad(x0: number, y0: number, x1: number, y1: number)
    local l, r = x0 / 128 - 0.5, x1 / 128 - 0.5
    local top, bottom = 0.5 - y0 / 32, 0.5 - y1 / 32
    push(t, l, bottom, NAME_Z, 0, 0, 1,  r, bottom, NAME_Z, 0, 0, 1,  r, top, NAME_Z, 0, 0, 1)
    push(t, l, bottom, NAME_Z, 0, 0, 1,  r, top, NAME_Z, 0, 0, 1,  l, top, NAME_Z, 0, 0, 1)
  end
  for letter = 1, #name do
    local rows = GLYPHS[string.sub(name, letter, letter)]
    if rows then
      local x = left + (letter - 1) * 18
      for row = 1, 7 do
        local function lit(col: number): boolean
          return bit32.band(rows[row], bit32.lshift(1, 4 - col)) ~= 0
        end
        local y = 5 + (row - 1) * 3
        local col = 0
        while col < 5 do
          if lit(col) then
            local last = col
            while last < 4 and lit(last + 1) do
              last += 1
            end
            quad(x + col * 3, y, x + (last + 1) * 3, y + 3)
            col = last + 1
          else
            col += 1
          end
        end
      end
    end
  end
  return t
end

-- Every level object in world space, one mesh: position, normal, colour and
-- material per vertex (10 floats). Boxes are axis aligned and positively
-- scaled, so their normals carry over unchanged.
local function levelData(): { number }
  local t: { number } = {}
  local cube, floor = cubeData(), floorData()
  for _, o in OBJECTS do
    local mesh = if o.mesh == 'floor' then floor else cube
    for v = 0, #mesh // 6 - 1 do
      local i = v * 6
      push(t, o.x + mesh[i + 1] * o.sx, o.y + mesh[i + 2] * o.sy, o.z + mesh[i + 3] * o.sz,
        mesh[i + 4], mesh[i + 5], mesh[i + 6], o.r, o.g, o.b, o.material or 0)
    end
  end
  return t
end

-- Opening title: pixel-font letters extruded into lit voxels, placed in
-- front of where we first look. Each letter pops in (staggered), hovers,
-- then lifts away; after that nothing is drawn.
local TITLE = 'GORIVE TAG'
local HUD_BASE = TITLE_BASE + #TITLE -- the rate readout's draws (see poseHud)
local HUD_MAX = 3 -- digits in the readout
local TITLE_PIXEL = 0.045   -- m per font pixel
local TITLE_DEPTH = 1.4     -- extrusion, in font pixels
local TITLE_DISTANCE = 3.2  -- m in front of the first head pose
local TITLE_RISE = 0.15     -- m above eye level
local TITLE_START = 0.6     -- s before the first letter
local TITLE_STAGGER = 0.09  -- s between letters
local TITLE_POP = 0.55      -- s for a letter to pop in
local TITLE_LEAVE = 5.2     -- s when the first letter starts to leave
local TITLE_EXIT = 0.6      -- s for a letter to leave

-- One letter as boxes, one per run of lit pixels in a row, in font pixels
-- around the glyph's centre (cube vertices, so it is lit like everything else).
local function letterData(rows: { number }): { number }
  local t: { number } = {}
  local cube = cubeData()
  local function run(c0: number, c1: number, row: number)
    local cx, cy, w = (c0 + c1 + 1) / 2 - 2.5, 3 - (row - 1), c1 - c0 + 1
    for v = 0, #cube // 6 - 1 do
      local i = v * 6
      push(t, cx + cube[i + 1] * w, cy + cube[i + 2], cube[i + 3] * TITLE_DEPTH,
        cube[i + 4], cube[i + 5], cube[i + 6])
    end
  end
  for row = 1, 7 do
    local col = 0
    while col < 5 do
      if bit32.band(rows[row], bit32.lshift(1, 4 - col)) ~= 0 then
        local last = col
        while last < 4 and bit32.band(rows[row], bit32.lshift(1, 4 - (last + 1))) ~= 0 do
          last += 1
        end
        run(col, last, row)
        col = last + 1
      else
        col += 1
      end
    end
  end
  return t
end

local function vertexBuffer(data: { number }): GPUBuffer
  local b = buffer.create(#data * 4)
  for i, v in data do
    buffer.writef32(b, (i - 1) * 4, v)
  end
  return GPUBuffer.new({ size = #data * 4, usage = 'vertex', data = b, immutable = true })
end

-- ---------------------------------------------------------------- math
-- Matrices are column-major arrays of 16 numbers (WGSL layout).

local function mul(a: { number }, b: { number }): { number }
  local r: { number } = table.create(16, 0)
  for c = 0, 3 do
    for row = 0, 3 do
      local s = 0
      for k = 0, 3 do
        s += a[k * 4 + row + 1] * b[c * 4 + k + 1]
      end
      r[c * 4 + row + 1] = s
    end
  end
  return r
end

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

local function writeMat(b: buffer, offset: number, m: { number })
  for i = 1, 16 do
    buffer.writef32(b, offset + (i - 1) * 4, m[i])
  end
end

-- Rotation matrix rows from a quaternion: r[row][col].
local function quatRows(x: number, y: number, z: number, w: number): { { number } }
  return {
    { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w) },
    { 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w) },
    { 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y) },
  }
end

local function viewFromPose(px: number, py: number, pz: number, r: { { number } }): { number }
  return {
    r[1][1], r[1][2], r[1][3], 0,
    r[2][1], r[2][2], r[2][3], 0,
    r[3][1], r[3][2], r[3][3], 0,
    -(r[1][1] * px + r[2][1] * py + r[3][1] * pz),
    -(r[1][2] * px + r[2][2] * py + r[3][2] * pz),
    -(r[1][3] * px + r[2][3] * py + r[3][3] * pz),
    1,
  }
end

local function projection(fovL: number, fovR: number, fovU: number, fovD: number): { number }
  local l, r = math.tan(fovL), math.tan(fovR)
  local u, d = math.tan(fovU), math.tan(fovD)
  local w, h = r - l, u - d
  return {
    2 / w, 0, 0, 0,
    0, 2 / h, 0, 0,
    (r + l) / w, (u + d) / h, -FAR / (FAR - NEAR), -1,
    0, 0, -(FAR * NEAR) / (FAR - NEAR), 0,
  }
end

-- Pose with per-axis scale and a local offset (pose space, unscaled).
local function poseModel(px: number, py: number, pz: number, r: { { number } },
                         sx: number, sy: number, sz: number,
                         ox: number, oy: number, oz: number): { number }
  return {
    r[1][1] * sx, r[2][1] * sx, r[3][1] * sx, 0,
    r[1][2] * sy, r[2][2] * sy, r[3][2] * sy, 0,
    r[1][3] * sz, r[2][3] * sz, r[3][3] * sz, 0,
    px + r[1][1] * ox + r[1][2] * oy + r[1][3] * oz,
    py + r[2][1] * ox + r[2][2] * oy + r[2][3] * oz,
    pz + r[3][1] * ox + r[3][2] * oy + r[3][3] * oz,
    1,
  }
end

-- Orthographic sun view fitted around SHADOW_BOUNDS, depth 0..1 across them.
local function lightMatrix(): { number }
  local len = math.sqrt(SUN[1] ^ 2 + SUN[2] ^ 2 + SUN[3] ^ 2)
  local z = { SUN[1] / len, SUN[2] / len, SUN[3] / len }
  -- Any x perpendicular to z; y = z cross x completes a right-handed basis.
  local xl = math.sqrt(z[2] ^ 2 + z[1] ^ 2)
  local x = { -z[2] / xl, z[1] / xl, 0 }
  local y = { z[2] * x[3] - z[3] * x[2], z[3] * x[1] - z[1] * x[3], z[1] * x[2] - z[2] * x[1] }
  local view = viewFromPose(0, 0, 0, {
    { x[1], y[1], z[1] }, { x[2], y[2], z[2] }, { x[3], y[3], z[3] },
  })
  local lo = { math.huge, math.huge, math.huge }
  local hi = { -math.huge, -math.huge, -math.huge }
  local b = SHADOW_BOUNDS
  for _, cx in { b[1], b[4] } do
    for _, cy in { b[2], b[5] } do
      for _, cz in { b[3], b[6] } do
        for a = 1, 3 do
          local v = view[a] * cx + view[4 + a] * cy + view[8 + a] * cz
          lo[a] = math.min(lo[a], v)
          hi[a] = math.max(hi[a], v)
        end
      end
    end
  end
  -- View space looks down -z: near is -hi[3], far is -lo[3].
  local w, h, d = hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3]
  local ortho = {
    2 / w, 0, 0, 0,
    0, 2 / h, 0, 0,
    0, 0, -1 / d, 0,
    -(hi[1] + lo[1]) / w, -(hi[2] + lo[2]) / h, hi[3] / d, 1,
  }
  return mul(ortho, view)
end

-- ---------------------------------------------------------------- state

local function num(self: VRScene, name: string): number
  local p = self.props[name]
  return if p then p.value else 0
end

-- World pose of a tracked thing: its play-space pose shifted by the rig.
-- The rig turns the play space by rigYaw about Y, then shifts it.
local function worldPoint(self: VRScene, prefix: string): (number, number, number)
  local x, z = num(self, prefix .. 'px'), num(self, prefix .. 'pz')
  local c, s = math.cos(self.rigYaw), math.sin(self.rigYaw)
  return self.rigX + c * x + s * z, self.rigY + num(self, prefix .. 'py'), self.rigZ - s * x + c * z
end

-- A tracked orientation turned by the rig: yaw quaternion * tracked one.
local function worldQuat(self: VRScene, prefix: string): (number, number, number, number)
  local sy, cy = math.sin(self.rigYaw / 2), math.cos(self.rigYaw / 2)
  local x, y = num(self, prefix .. 'qx'), num(self, prefix .. 'qy')
  local z, w = num(self, prefix .. 'qz'), num(self, prefix .. 'qw')
  return cy * x + sy * z, cy * y + sy * w, cy * z - sy * x, cy * w - sy * y
end

local function poseOf(self: VRScene, prefix: string): (number, number, number, { { number } })
  local x, y, z = worldPoint(self, prefix)
  return x, y, z, quatRows(worldQuat(self, prefix))
end

-- ---------------------------------------------------------------- locomotion
-- Gorilla Tag style, no sticks (after the open source GorillaLocomotion).
-- Each frame each hand is swept from where it was to where it is now. If a
-- surface blocks it, the hand stays put and the body moves instead, so
-- pushing a hand down lifts you and pulling it back moves you forward. A hand
-- that moves away from the surface is simply free again. The body keeps a
-- short velocity history; while any hand is touching and that velocity is
-- above a small limit it becomes momentum, so a hard push flings you as the
-- hand comes off. Gravity applies whenever no hand is touching.

local HAND_RADIUS = 0.06
local MAX_ARM_LENGTH = 1.0 -- a stuck hand lets go beyond this from the real hand
local FEET_RADIUS = 0.2
-- The body hangs this far below the head (1.5 ft), gorilla style: the feet
-- rest here, not at your real floor, so the ground stays within arm's reach.
local BODY_HEIGHT = 0.46
local HEAD_RADIUS = 0.15
local GRAVITY = 9.8
local JUMP_MULTIPLIER = 1.3
local MAX_JUMP_SPEED = 6.5
local VELOCITY_LIMIT = 0.4 -- below this a touching body just holds still
local HISTORY = 8 -- frames of body velocity averaged for jumps
local GROUND_FRICTION = 4
local SWEEP_STEPS = 4

type Box = { x0: number, x1: number, y0: number, y1: number, z0: number, z1: number }
local COLLIDERS: { Box } = {
  { x0 = -1000, x1 = 1000, y0 = -10, y1 = 0, z0 = -1000, z1 = 1000 }, -- floor
}
for _, o in OBJECTS do
  if o.mesh == 'cube' and not o.decorative then
    table.insert(COLLIDERS, {
      x0 = o.x - o.sx / 2, x1 = o.x + o.sx / 2,
      y0 = o.y - o.sy / 2, y1 = o.y + o.sy / 2,
      z0 = o.z - o.sz / 2, z1 = o.z + o.sz / 2,
    })
  end
end

-- Pushes a sphere out of the colliders it overlaps. Returns the push.
local function pushOut(x: number, y: number, z: number, r: number): (number, number, number)
  local px, py, pz = 0, 0, 0
  for _ = 1, 2 do
    for _, b in COLLIDERS do
      local cx, cy, cz = x + px, y + py, z + pz
      local dx = cx - math.clamp(cx, b.x0, b.x1)
      local dy = cy - math.clamp(cy, b.y0, b.y1)
      local dz = cz - math.clamp(cz, b.z0, b.z1)
      local d2 = dx * dx + dy * dy + dz * dz
      if d2 < r * r then
        if d2 > 1e-10 then
          local d = math.sqrt(d2)
          local k = (r - d) / d
          px += dx * k
          py += dy * k
          pz += dz * k
        else
          -- Centre inside the box: leave through the nearest face.
          local moves: { { number } } = {
            { b.x0 - r - cx, 0, 0 }, { b.x1 + r - cx, 0, 0 },
            { 0, b.y0 - r - cy, 0 }, { 0, b.y1 + r - cy, 0 },
            { 0, 0, b.z0 - r - cz }, { 0, 0, b.z1 + r - cz },
          }
          local best = moves[1]
          for _, m in moves do
            if math.abs(m[1] + m[2] + m[3]) < math.abs(best[1] + best[2] + best[3]) then
              best = m
            end
          end
          px += best[1]
          py += best[2]
          pz += best[3]
        end
      end
    end
  end
  return px, py, pz
end

-- Sweeps a hand sphere from a to b. Returns the contact centre if a surface
-- blocks it on the way.
local function sweepHand(ax: number, ay: number, az: number,
                         bx: number, by: number, bz: number): (boolean, number, number, number)
  for i = 1, SWEEP_STEPS do
    local t = i / SWEEP_STEPS
    local x, y, z = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
    local px, py, pz = pushOut(x, y, z, HAND_RADIUS)
    if px ~= 0 or py ~= 0 or pz ~= 0 then
      return true, x + px, y + py, z + pz
    end
  end
  return false, bx, by, bz
end

local function locomote(self: VRScene, seconds: number)
  local dt = math.clamp(seconds, 1 / 240, 1 / 30)
  local startX, startY, startZ = self.rigX, self.rigY, self.rigZ

  -- Momentum and gravity move the body first; touching hands correct it.
  local wasTouching = self.hands[1].touching or self.hands[2].touching
  if not wasTouching then
    self.velY -= GRAVITY * dt
  end
  self.rigX += self.velX * dt
  self.rigY += self.velY * dt
  self.rigZ += self.velZ * dt

  -- Hands: sweep from last frame's position to where the real hand is now.
  local bias = 2 * GRAVITY * dt * dt -- keeps a resting hand in contact
  local mx, my, mz, touching = 0, 0, 0, 0
  local targets: { { number } } = {}
  for h, hand in { 'L', 'R' } do
    local st = self.hands[h]
    local g = 'grip' .. hand .. '_'
    local tx, ty, tz = worldPoint(self, g)
    targets[h] = { tx, ty, tz }
    if num(self, 'active' .. hand) < 0.5 then
      st.touching = false
      st.ready = false
      continue
    end
    if not st.ready then
      st.x, st.y, st.z = tx, ty, tz
      st.ready = true
    end
    local hit, cx, cy, cz = sweepHand(st.x, st.y, st.z, tx, ty - bias, tz)
    if hit then
      -- Keep touching where it first touched; a new touch sticks at contact.
      local hx, hy, hz = if st.touching then st.x else cx, if st.touching then st.y else cy,
        if st.touching then st.z else cz
      local ox, oy, oz = hx - tx, hy - ty, hz - tz
      if ox * ox + oy * oy + oz * oz > MAX_ARM_LENGTH * MAX_ARM_LENGTH then
        st.touching = false
      else
        st.touching = true
        st.x, st.y, st.z = hx, hy, hz
        mx += ox
        my += oy
        mz += oz
        touching += 1
      end
    else
      st.touching = false
    end
  end

  if touching > 0 then
    self.rigX += mx / touching
    self.rigY += my / touching
    self.rigZ += mz / touching
  end
  -- Free hands travel with the body.
  for h = 1, 2 do
    local st = self.hands[h]
    if st.ready and not st.touching then
      local t = targets[h]
      st.x = t[1] + (if touching > 0 then mx / touching else 0)
      st.y = t[2] + (if touching > 0 then my / touching else 0)
      st.z = t[3] + (if touching > 0 then mz / touching else 0)
    end
  end

  -- Body: a short body under the head, and the head itself, push out of
  -- geometry.
  local hx, hy, hz = worldPoint(self, 'eyeL_')
  local px, py, pz = pushOut(hx, hy - BODY_HEIGHT + FEET_RADIUS, hz, FEET_RADIUS)
  self.rigX += px
  self.rigY += py
  self.rigZ += pz
  local onFeet = py > 0
  px, py, pz = pushOut(hx + px, hy + py, hz + pz, HEAD_RADIUS)
  self.rigX += px
  self.rigY += py
  self.rigZ += pz

  -- Velocity: what the body actually did, averaged over recent frames.
  table.insert(self.history, {
    (self.rigX - startX) / dt, (self.rigY - startY) / dt, (self.rigZ - startZ) / dt,
  })
  if #self.history > HISTORY then
    table.remove(self.history, 1)
  end
  if touching > 0 then
    local ax, ay, az = 0, 0, 0
    for _, v in self.history do
      ax += v[1]
      ay += v[2]
      az += v[3]
    end
    local n = #self.history
    ax, ay, az = ax / n, ay / n, az / n
    local speed = math.sqrt(ax * ax + ay * ay + az * az)
    if speed > VELOCITY_LIMIT then
      -- Moving hard while touching: that becomes momentum, so the push flings.
      local k = math.min(JUMP_MULTIPLIER, MAX_JUMP_SPEED / speed)
      self.velX, self.velY, self.velZ = ax * k, ay * k, az * k
    else
      self.velX, self.velY, self.velZ = 0, 0, 0
    end
  elseif onFeet then
    -- Landed on the body: stop falling, keep some slide.
    self.velY = math.max(self.velY, 0)
    local f = math.max(0, 1 - GROUND_FRICTION * dt)
    self.velX *= f
    self.velZ *= f
  end
  if py < 0 and self.velY > 0 then
    self.velY = 0 -- bumped the head
  end

  -- Fell out of the world: back to the start, facing the court again.
  if self.rigY < -30 then
    self.aligned = false
  end
end

-- ---------------------------------------------------------------- lifecycle

local function colorTexture(w: number, h: number, samples: number, label: string): GPUTextureView?
  if samples <= 1 then
    return nil
  end
  return GPUTexture.new({
    width = w, height = h, format = 'rgba8unorm',
    renderTarget = true, sampleCount = samples, label = label,
  }):view()
end

local function depthTexture(w: number, h: number, samples: number, label: string): GPUTextureView
  return GPUTexture.new({
    width = w, height = h, format = DEPTH_FORMAT,
    renderTarget = true, sampleCount = samples, label = label,
  }):view()
end

-- Per-eye uniforms and bind groups; the canvas path also gets its own
-- gpuCanvas and attachments.
local function makeEye(self: VRScene, w: number, h: number, withCanvas: boolean): Eye
  local context = self.context :: Context
  local eye: Eye = {
    canvas = if withCanvas then context:gpuCanvas({ width = w, height = h }) else nil,
    msaaView = if withCanvas then colorTexture(w, h, self.samples, 'eye-msaa') else nil,
    depthView = if withCanvas then depthTexture(w, h, self.samples, 'eye-depth') else nil,
    ubos = {},
    groups = {},
  }
  for _ = 1, HUD_BASE + HUD_MAX do
    local ubo = GPUBuffer.new({ size = UBO_SIZE, usage = 'uniform' })
    table.insert(eye.ubos, ubo)
    table.insert(eye.groups, GPUBindGroup.new({
      layout = self.drawLayout :: GPUBindGroupLayout,
      ubos = { { slot = 0, buffer = ubo } },
    }))
  end
  return eye
end

-- The pipeline depends on the sample count and, for the direct path, flipped
-- culling; rebuilt whenever either changes.
-- Vertex layouts: posed parts (position, normal) and the baked level
-- (position, normal, colour, material).
local PART_LAYOUT: { VertexBufferLayout } = { {
  stride = 24,
  attributes = {
    { format = 'float32x3', slot = 0, offset = 0 },
    { format = 'float32x3', slot = 1, offset = 12 },
  },
} }
local LEVEL_LAYOUT: { VertexBufferLayout } = { {
  stride = 40,
  attributes = {
    { format = 'float32x3', slot = 0, offset = 0 },
    { format = 'float32x3', slot = 1, offset = 12 },
    { format = 'float32x3', slot = 2, offset = 24 },
    { format = 'float32', slot = 3, offset = 36 },
  },
} }

local function buildPipelines(self: VRScene, samples: number, cull: CullMode)
  local lit = self.litShader :: Shader
  local function make(entry: string, layout: { VertexBufferLayout }): GPUPipeline
    return GPUPipeline.new({
      vertex = { module = lit, entryPoint = entry },
      fragment = { module = lit, entryPoint = 'fs' },
      vertexLayout = layout,
      colorTargets = { { format = 'rgba8unorm' } },
      depthStencil = { format = DEPTH_FORMAT, compare = 'less', write = true },
      cullMode = cull,
      sampleCount = samples,
      bindGroupLayouts = { self.drawLayout :: GPUBindGroupLayout, self.shadowLayout :: GPUBindGroupLayout },
    })
  end
  self.pipeline = make('vs', PART_LAYOUT)
  self.levelPipeline = make('vsLevel', LEVEL_LAYOUT)
end

-- The sun's depth pass and the map it renders, sampled by the lit pipeline.
-- Independent of the eye configuration, so built once.
local function buildShadows(self: VRScene, lit: Shader)
  self.drawLayout = GPUBindGroupLayout.new({ shader = lit, groupIndex = 0 })
  self.shadowLayout = GPUBindGroupLayout.new({ shader = lit, groupIndex = 1 })
  local function make(entry: string, layout: { VertexBufferLayout }): GPUPipeline
    return GPUPipeline.new({
      vertex = { module = lit, entryPoint = entry },
      vertexLayout = layout,
      depthStencil = { format = SHADOW_FORMAT, compare = 'less', write = true },
      cullMode = 'none',
      -- The shader file's layout includes group 1, so the depth pass needs it
      -- too; it binds a 1x1 placeholder rather than the map it is writing.
      bindGroupLayouts = { self.drawLayout :: GPUBindGroupLayout, self.shadowLayout :: GPUBindGroupLayout },
    })
  end
  self.shadowPipeline = make('vsShadow', PART_LAYOUT)
  self.levelShadowPipeline = make('vsShadowLevel', LEVEL_LAYOUT)
  local sampler = GPUSampler.new({
    min = 'linear', mag = 'linear', compare = 'less-equal',
    wrapU = 'clamp-to-edge', wrapV = 'clamp-to-edge',
  })
  local skinSampler = GPUSampler.new({ min = 'linear', mag = 'linear' })
  local function depth(size: number, label: string): GPUTextureView
    return GPUTexture.new({
      width = size, height = size, format = SHADOW_FORMAT, renderTarget = true, label = label,
    }):view()
  end
  local function group(shadow: GPUTextureView, skin: Skin): GPUBindGroup
    return GPUBindGroup.new({
      layout = self.shadowLayout :: GPUBindGroupLayout,
      textures = { { slot = 0, view = shadow }, { slot = 2, view = skin.canvas.image:view() } },
      samplers = { { slot = 1, sampler = sampler }, { slot = 3, sampler = skinSampler } },
    })
  end
  local view = depth(SHADOW_SIZE, 'sun-shadow')
  self.shadowView = view
  for _, skin in self.skins do
    skin.group = group(view, skin)
  end
  -- Unskinned draws sample no skin, but the layout needs one bound.
  self.shadowGroup = group(view, self.skins[SELF_SKIN])
  self.shadowPassGroup = group(depth(1, 'sun-shadow-placeholder'), self.skins[SELF_SKIN])
  -- The sun never moves: its matrix stays in every upload's last 64 bytes.
  self.lightViewProj = lightMatrix()
  writeMat(self.staging, 160, self.lightViewProj)
end

-- Rebuilds the pipeline, eyes and the direct-path attachments for a new
-- resolution, sample count or output path.
local function configure(self: VRScene, w: number, h: number, samples: number, direct: boolean)
  self.samples = samples
  self.direct = direct
  buildPipelines(self, samples, if direct then 'front' else 'back')
  self.eyes = { makeEye(self, w, h, not direct), makeEye(self, w, h, not direct) }
  if direct then
    self.directMsaa = colorTexture(w * 2, h, samples, 'direct-msaa')
    self.directDepth = depthTexture(w * 2, h, samples, 'direct-depth')
  else
    self.directMsaa = nil
    self.directDepth = nil
  end
  self.width = w
  self.height = h
  print(string.format('VRScene: %dx%d per eye, msaa %d, %s path', w, h, samples,
    if direct then 'direct' else 'canvas'))
end

function init(self: VRScene, context: Context): boolean
  self.context = context
  local vm = context:viewModel()
  if vm then
    for _, name in PROP_NAMES do
      local p = vm:getNumber(name)
      if p then
        self.props[name] = p
      end
    end
  end
  local shader = context:shader('scene_lit')
  if shader == nil then
    print('VRScene: missing shader scene_lit')
    return false
  end
  for _, name in PLAYER_NAMES do
    local data = nameData(name)
    table.insert(self.nameVerts, vertexBuffer(data))
    table.insert(self.nameCounts, #data // 6)
  end
  self.litShader = shader
  local ok, err = pcall(function()
    for _ = 1, SELF_SKIN do
      local vm = Data.Skin.new()
      table.insert(self.skins, {
        vm = vm, instance = self.skinArtboard:instance(vm),
        canvas = context:canvas({ width = SKIN_W, height = SKIN_H }),
        group = nil, lookX = 0, lookY = 0, mouth = SKIN_MOUTH_REST,
        hx = 0, hy = 0, hz = 0, active = false,
      })
    end
  end)
  if not ok then
    print('VRScene: no Skin artboard (' .. tostring(err) .. ')')
    return false
  end
  buildShadows(self, shader)
  for k = 1, #TITLE do
    local rows = GLYPHS[string.sub(TITLE, k, k)]
    if rows then
      local data = letterData(rows)
      table.insert(self.titleLetters, {
        verts = vertexBuffer(data), count = #data // 6, index = k - 1,
        colour = PLAYER_COLOURS[(#self.titleLetters % #PLAYER_COLOURS) + 1],
      })
    end
  end
  for d = 0, 9 do
    local data = letterData(GLYPHS[tostring(d)])
    table.insert(self.hudDigits, {
      verts = vertexBuffer(data), count = #data // 6, index = d, colour = HUD_COLOUR,
    })
  end
  self.cubeVerts = vertexBuffer(cubeData())
  local level = levelData()
  self.levelVerts = vertexBuffer(level)
  self.levelCount = #level // 10
  self.sampler = ImageSampler('clamp', 'clamp', 'nearest')
  return true
end

local function setNum(self: VRScene, name: string, value: number)
  local p = self.props[name]
  if p then
    p.value = value
  end
end

-- Our world-space head (between the eyes) and hands, for the host to send.
-- A touching hand reports where it touches, matching what we draw.
local function publishPose(self: VRScene)
  local function write(part: string, x: number, y: number, z: number, q: string)
    setNum(self, part .. '_px', x)
    setNum(self, part .. '_py', y)
    setNum(self, part .. '_pz', z)
    local qx, qy, qz, qw = worldQuat(self, q)
    setNum(self, part .. '_qx', qx)
    setNum(self, part .. '_qy', qy)
    setNum(self, part .. '_qz', qz)
    setNum(self, part .. '_qw', qw)
  end
  local lx, ly, lz = poseOf(self, 'eyeL_')
  local rx, ry, rz = poseOf(self, 'eyeR_')
  write('netHead', (lx + rx) / 2, (ly + ry) / 2, (lz + rz) / 2, 'eyeL_')
  for h, hand in { 'L', 'R' } do
    local x, y, z = poseOf(self, 'grip' .. hand .. '_')
    local st = self.hands[h]
    if st.touching then
      x, y, z = st.x, st.y, st.z
    end
    if num(self, 'active' .. hand) < 0.5 then
      x, y, z = 0, -100, 0 -- hidden
    end
    write('netHand' .. hand, x, y, z, 'grip' .. hand .. '_')
  end
end

-- ---------------------------------------------------------------- monke
-- Remote players as Gorilla Tag style box monkes, posed from only the head
-- and hands they send. The torso hangs under the head and turns with its
-- yaw alone, easing after it but never twisting more than MONKE_MAX_TWIST
-- away. Each arm is a two-bone reach from a shoulder to the wrist, the elbow
-- bending out, down and back; arms stretch rather than let go of a hand out
-- of reach. Every part is a rigid box, so there is no skinning. We see our
-- own arms the same way, in place of controllers, but not our head or torso.

local MONKE_HEAD: { number } = { 0.26, 0.24, 0.26 }
local MONKE_HEAD_BACK = 0.06 -- head centre behind the eyes
local MONKE_FACE: { number } = { 0.19, 0.15, 0.02 }
local MONKE_NECK = 0.14 -- neck below the head centre
local MONKE_TORSO: { number } = { 0.36, 0.42, 0.28 }
local MONKE_BELLY: { number } = { 0.24, 0.26, 0.02 }
local MONKE_SHOULDER: { number } = { 0.2, -0.07, 0.02 } -- from the neck, body space (x for the right)
local MONKE_UPPER_ARM = 0.36
local MONKE_FOREARM = 0.36
local MONKE_ARM_WIDTH = 0.085
local MONKE_HAND: { number } = { 0.1, 0.06, 0.13 }
local MONKE_WRIST = 0.07 -- wrist behind the grip, hand space
local MONKE_ELBOW_POLE: { number } = { 0.6, -0.6, 0.5 } -- body space (x for the right)
local MONKE_REST_HAND: { number } = { 0.04, -0.62, -0.1 } -- from the shoulder, untracked hands
local MONKE_TURN_RATE = 4 -- 1/s, how fast the torso eases after the head
local MONKE_MAX_TWIST = math.rad(45)
local MONKE_SKIN: { number } = { 0.82, 0.68, 0.52 } -- face and belly
-- Our own fur while offline. Online, netColor is our id % 8, the colour
-- peers draw us in.
local SELF_COLOUR: { number } = { 0.45, 0.32, 0.24 }

local function emptyMonkes(): { Monke }
  local t: { Monke } = {}
  for _ = 1, REMOTE_SLOTS do
    local m: Monke = { key = -1, yaw = 0, x = 0, y = 0, z = 0, parts = {} }
    table.insert(t, m)
  end
  return t
end

local function remotePose(self: VRScene, prefix: string): (number, number, number, { { number } })
  return num(self, prefix .. 'px'), num(self, prefix .. 'py'), num(self, prefix .. 'pz'),
    quatRows(num(self, prefix .. 'qx'), num(self, prefix .. 'qy'),
             num(self, prefix .. 'qz'), num(self, prefix .. 'qw'))
end

local function yawRows(yaw: number): { { number } }
  local c, s = math.cos(yaw), math.sin(yaw)
  return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } }
end

local function wrapAngle(a: number): number
  return (a + math.pi) % (2 * math.pi) - math.pi
end

-- The yaw a head faces (0 is -Z). Looking straight down or up its forward
-- axis is vertical, so the head's up axis, which then points level, fills in.
local function headYaw(r: { { number } }): number
  local fy = -r[2][3]
  local dx = -r[1][3] - r[1][2] * fy
  local dz = -r[3][3] - r[3][2] * fy
  return math.atan2(-dx, -dz)
end

-- p + r * (x, y, z)
local function offset(px: number, py: number, pz: number, r: { { number } },
                      x: number, y: number, z: number): (number, number, number)
  return px + r[1][1] * x + r[1][2] * y + r[1][3] * z,
    py + r[2][1] * x + r[2][2] * y + r[2][3] * z,
    pz + r[3][1] * x + r[3][2] * y + r[3][3] * z
end

-- A unit vector perpendicular to unit u, as close to hint as possible.
local function perpendicular(ux: number, uy: number, uz: number,
                             hx: number, hy: number, hz: number): (number, number, number)
  for _, h in { { hx, hy, hz }, { 0, -1, 0 }, { 1, 0, 0 } } do
    local k = h[1] * ux + h[2] * uy + h[3] * uz
    local x, y, z = h[1] - k * ux, h[2] - k * uy, h[3] - k * uz
    local len = math.sqrt(x * x + y * y + z * z)
    if len > 1e-3 then
      return x / len, y / len, z / len
    end
  end
  return 1, 0, 0
end

-- Two-bone reach from shoulder s to wrist w; returns the elbow, which bends
-- towards the pole. Out of reach, both bones stretch to keep the hand on.
local function elbowOf(sx: number, sy: number, sz: number, wx: number, wy: number, wz: number,
                       px: number, py: number, pz: number): (number, number, number)
  local dx, dy, dz = wx - sx, wy - sy, wz - sz
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  if d < 1e-4 then
    return sx + px * MONKE_UPPER_ARM, sy + py * MONKE_UPPER_ARM, sz + pz * MONKE_UPPER_ARM
  end
  local ux, uy, uz = dx / d, dy / d, dz / d
  local nx, ny, nz = perpendicular(ux, uy, uz, px, py, pz)
  local stretch = math.max(1, d / (MONKE_UPPER_ARM + MONKE_FOREARM))
  local a, b = MONKE_UPPER_ARM * stretch, MONKE_FOREARM * stretch
  local cosA = math.clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1)
  local along, across = a * cosA, a * math.sqrt(1 - cosA * cosA)
  return sx + ux * along + nx * across, sy + uy * along + ny * across, sz + uz * along + nz * across
end

-- A square bar of the given width from a to b, rolled towards side.
local function barModel(ax: number, ay: number, az: number, bx: number, by: number, bz: number,
                        width: number, sx: number, sy: number, sz: number): { number }
  local zx, zy, zz = bx - ax, by - ay, bz - az
  local len = math.max(math.sqrt(zx * zx + zy * zy + zz * zz), 1e-4)
  zx, zy, zz = zx / len, zy / len, zz / len
  local xx, xy, xz = perpendicular(zx, zy, zz, sx, sy, sz)
  local yx, yy, yz = zy * xz - zz * xy, zz * xx - zx * xz, zx * xy - zy * xx
  return {
    xx * width, xy * width, xz * width, 0,
    yx * width, yy * width, yz * width, 0,
    zx * len, zy * len, zz * len, 0,
    (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2, 1,
  }
end

-- Eases a torso yaw after the head's, never more than MONKE_MAX_TWIST behind.
local function turnTowards(yaw: number, target: number, dt: number): number
  yaw += wrapAngle(target - yaw) * (1 - math.exp(-MONKE_TURN_RATE * dt))
  local twist = wrapAngle(target - yaw)
  if math.abs(twist) > MONKE_MAX_TWIST then
    yaw = target - math.sign(twist) * MONKE_MAX_TWIST
  end
  return wrapAngle(yaw)
end

-- Neck (below the head centre) for a head pose.
local function neckOf(hx: number, hy: number, hz: number, hr: { { number } }): (number, number, number)
  local cx, cy, cz = offset(hx, hy, hz, hr, 0, 0, MONKE_HEAD_BACK)
  return cx, cy - MONKE_NECK, cz
end

-- Appends an upper arm, forearm and hand reaching from the shoulder on side
-- (-1 left, 1 right) of a torso at neck n facing br, to the hand pose a. A
-- hand far below the floor was sent hidden (untracked) and hangs at the side.
local function addArm(parts: { Part }, nx: number, ny: number, nz: number, br: { { number } },
                      side: number, ax: number, ay: number, az: number, ar: { { number } })
  local sx, sy, sz = offset(nx, ny, nz, br,
    side * MONKE_SHOULDER[1], MONKE_SHOULDER[2], MONKE_SHOULDER[3])
  if ay < -50 then
    ax, ay, az = offset(sx, sy, sz, br, side * MONKE_REST_HAND[1], MONKE_REST_HAND[2], MONKE_REST_HAND[3])
    ar = br
  end
  local wx, wy, wz = offset(ax, ay, az, ar, 0, 0, MONKE_WRIST)
  local px, py, pz = offset(0, 0, 0, br,
    side * MONKE_ELBOW_POLE[1], MONKE_ELBOW_POLE[2], MONKE_ELBOW_POLE[3])
  local ex, ey, ez = elbowOf(sx, sy, sz, wx, wy, wz, px, py, pz)
  table.insert(parts, { model = barModel(sx, sy, sz, ex, ey, ez, MONKE_ARM_WIDTH, px, py, pz),
    r = 1, g = 1, b = 1, mode = 13 })
  table.insert(parts, { model = barModel(ex, ey, ez, wx, wy, wz, MONKE_ARM_WIDTH * 0.92, px, py, pz),
    r = 0.92, g = 0.92, b = 0.92, mode = 13 })
  table.insert(parts, { model = poseModel(ax, ay, az, ar, MONKE_HAND[1], MONKE_HAND[2], MONKE_HAND[3],
      0, 0, 0), r = 0.7, g = 0.7, b = 0.7, mode = 13 })
end

-- Poses one slot's monke for this frame (both eyes then share it).
-- Skin expressions. Eyes find whoever is looking at this player (the
-- viewer), within the eye whites; the mouth opens with head speed.

-- Updates one skin's view model and advances its state machine.
local function express(self: VRScene, skin: Skin, colour: { number },
                 hx: number, hy: number, hz: number, hr: { { number } }, dt: number)
  local vm = skin.vm
  local instance = skin.instance
  if vm == nil or instance == nil then
    return
  end
  skin.active = true
  -- The viewer in the head's frame (rows of hr are its axes in world space).
  local lx, ly, lz = poseOf(self, 'eyeL_')
  local rx, ry, rz = poseOf(self, 'eyeR_')
  local dx, dy, dz = (lx + rx) / 2 - hx, (ly + ry) / 2 - hy, (lz + rz) / 2 - hz
  local ax = hr[1][1] * dx + hr[2][1] * dy + hr[3][1] * dz
  local ay = hr[1][2] * dx + hr[2][2] * dy + hr[3][2] * dz
  local az = hr[1][3] * dx + hr[2][3] * dy + hr[3][3] * dz
  local len = math.max(1e-4, math.sqrt(ax * ax + ay * ay + az * az))
  -- The face is seen from -Z: its texture runs right to left in local x,
  -- and down in local y.
  local tx, ty = -ax / len * SKIN_LOOK, -ay / len * SKIN_LOOK
  local speed = if dt > 0
    then math.sqrt((hx - skin.hx) ^ 2 + (hy - skin.hy) ^ 2 + (hz - skin.hz) ^ 2) / dt
    else 0
  skin.hx, skin.hy, skin.hz = hx, hy, hz
  local open = math.clamp(speed / SKIN_MOUTH_SPEED, 0, 1)
  local tm = SKIN_MOUTH_REST + (SKIN_MOUTH_OPEN - SKIN_MOUTH_REST) * open
  local e = 1 - math.exp(-SKIN_EASE * dt)
  skin.lookX += (tx - skin.lookX) * e
  skin.lookY += (ty - skin.lookY) * e
  skin.mouth += (tm - skin.mouth) * e
  vm.lookX.value = skin.lookX
  vm.lookY.value = skin.lookY
  vm.mouth.value = skin.mouth
  vm.fur.value = Color.rgb(math.floor(colour[1] * 255), math.floor(colour[2] * 255),
    math.floor(colour[3] * 255))
  instance:advance(dt)
end

local function poseMonke(self: VRScene, slot: number, dt: number)
  local p = 'p' .. slot .. '_'
  local m = self.monkes[slot]
  self.skins[slot].active = false
  if num(self, p .. 'active') < 0.5 then
    m.key = -1
    return
  end
  local key = math.floor(num(self, p .. 'color'))
  local c = PLAYER_COLOURS[key % #PLAYER_COLOURS + 1]
  local hx, hy, hz, hr = remotePose(self, p .. 'head_')
  local target = headYaw(hr)
  if m.key ~= key then
    m.key = key
    m.yaw = target
  else
    m.yaw = turnTowards(m.yaw, target, dt)
  end
  local br = yawRows(m.yaw)
  local nx, ny, nz = neckOf(hx, hy, hz, hr)
  m.x, m.y, m.z = nx, ny + MONKE_NECK, nz

  local parts: { Part } = {
    { model = poseModel(hx, hy, hz, hr, MONKE_HEAD[1], MONKE_HEAD[2], MONKE_HEAD[3],
        0, 0, MONKE_HEAD_BACK), r = 1, g = 1, b = 1, mode = 13 },
    { model = poseModel(hx, hy, hz, hr, MONKE_FACE[1], MONKE_FACE[2], MONKE_FACE[3],
        0, -0.015, MONKE_HEAD_BACK - MONKE_HEAD[3] / 2 - MONKE_FACE[3] / 2 + 0.005),
      r = 1, g = 1, b = 1, mode = 12 },
    { model = poseModel(nx, ny, nz, br, MONKE_TORSO[1], MONKE_TORSO[2], MONKE_TORSO[3],
        0, -MONKE_TORSO[2] / 2, 0), r = 1, g = 1, b = 1, mode = 13 },
    { model = poseModel(nx, ny, nz, br, MONKE_BELLY[1], MONKE_BELLY[2], MONKE_BELLY[3],
        0, -MONKE_TORSO[2] / 2 - 0.03, -MONKE_TORSO[3] / 2 - MONKE_BELLY[3] / 2 + 0.005),
      r = MONKE_SKIN[1], g = MONKE_SKIN[2], b = MONKE_SKIN[3], mode = 0 },
  }
  for i, part in { 'handL_', 'handR_' } do
    local ax, ay, az, ar = remotePose(self, p .. part)
    addArm(parts, nx, ny, nz, br, if i == 1 then -1 else 1, ax, ay, az, ar)
  end
  m.parts = parts
  express(self, self.skins[slot], c, hx, hy, hz, hr, dt)
end

-- Our own arms, from our head and the hands as we draw them (where they
-- touch, while touching). Untracked hands draw nothing.
local function poseSelf(self: VRScene, dt: number)
  local lx, ly, lz, hr = poseOf(self, 'eyeL_')
  local rx, ry, rz = poseOf(self, 'eyeR_')
  local hx, hy, hz = (lx + rx) / 2, (ly + ry) / 2, (lz + rz) / 2
  local target = headYaw(hr)
  local yaw = if self.selfYaw then turnTowards(self.selfYaw, target, dt) else target
  self.selfYaw = yaw
  local br = yawRows(yaw)
  local nx, ny, nz = neckOf(hx, hy, hz, hr)
  local key = if self.props.netColor then math.floor(num(self, 'netColor')) else -1
  local colour = if key >= 0 then PLAYER_COLOURS[key % #PLAYER_COLOURS + 1] else SELF_COLOUR
  for h, hand in { 'L', 'R' } do
    if num(self, 'active' .. hand) > 0.5 then
      local ax, ay, az, ar = poseOf(self, 'grip' .. hand .. '_')
      local st = self.hands[h]
      if st.touching then
        ax, ay, az = st.x, st.y, st.z
      end
      local parts: { Part } = {}
      addArm(parts, nx, ny, nz, br, if h == 1 then -1 else 1, ax, ay, az, ar)
      self.selfArms[h] = parts
    else
      self.selfArms[h] = nil
    end
  end
  local skin = self.skins[SELF_SKIN]
  skin.active = self.selfArms[1] ~= nil or self.selfArms[2] ~= nil
  if skin.active then
    express(self, skin, colour, hx, hy, hz, hr, dt)
  end
end

local function easeOutBack(t: number): number
  local c = 1.9
  return 1 + (c + 1) * (t - 1) ^ 3 + c * (t - 1) ^ 2
end

-- Places the title once the head is tracked, then poses its letters.
local function poseTitle(self: VRScene, dt: number)
  self.titleShown = {}
  if self.titleTime < 0 then
    if num(self, 'eyeL_qw') == 0 and num(self, 'eyeL_qy') == 0 then
      return -- no head pose yet
    end
    local lx, ly, lz, hr = poseOf(self, 'eyeL_')
    local rx, ry, rz = poseOf(self, 'eyeR_')
    self.titleYaw = headYaw(hr)
    local fx, fz = -math.sin(self.titleYaw), -math.cos(self.titleYaw)
    self.titleX = (lx + rx) / 2 + fx * TITLE_DISTANCE
    self.titleY = (ly + ry) / 2 + TITLE_RISE
    self.titleZ = (lz + rz) / 2 + fz * TITLE_DISTANCE
    self.titleTime = 0
  end
  local time = self.titleTime + dt
  self.titleTime = time
  local last = TITLE_LEAVE + (#TITLE - 1) * TITLE_STAGGER * 0.5 + TITLE_EXIT
  if time > last then
    return
  end
  -- Letters face back along our first view; +x reads left to right.
  local c, s = math.cos(self.titleYaw), math.sin(self.titleYaw)
  local span = (#TITLE - 1) * 6
  for i, letter in self.titleLetters do
    local k = letter.index
    local t = math.clamp((time - TITLE_START - k * TITLE_STAGGER) / TITLE_POP, 0, 1)
    local leave = math.clamp((time - TITLE_LEAVE - k * TITLE_STAGGER * 0.5) / TITLE_EXIT, 0, 1)
    local scale = easeOutBack(t) * (1 - leave * leave)
    if scale > 0.001 then
      local along = (k * 6 - span / 2) * TITLE_PIXEL
      local lift = (1 - t) ^ 3 * -0.35 + leave * leave * 0.9
        + math.sin(time * 2.2 + k * 0.7) * 0.025
      local spin = (1 - t) ^ 2 * 1.4 - leave * 0.8
      local model = poseModel(self.titleX + c * along, self.titleY + lift, self.titleZ - s * along,
        yawRows(self.titleYaw + spin),
        TITLE_PIXEL * scale, TITLE_PIXEL * scale, TITLE_PIXEL * scale, 0, 0, 0)
      local col = letter.colour
      self.titleParts[i] = { model = model, r = col[1], g = col[2], b = col[3], mode = 0 }
      table.insert(self.titleShown, i)
    end
  end
end

-- Refresh rate readout: when the display rate changes, its number shows in
-- the title's block font, head-locked in front of us for HUD_TIME seconds.
-- The rate comes from the frame time, which the host derives from the
-- runtime's display times, so it is the rate actually running, not just the
-- one asked for; it must hold for HUD_SETTLE frames so a dropped frame does
-- not count as a change.
local HUD_DISTANCE = 1.2  -- m in front of the eyes
local HUD_DROP = 0.06     -- m below eye level
local HUD_PIXEL = 0.012   -- m per font pixel
local HUD_TIME = 3        -- s on screen
local HUD_POP = 0.25      -- s to pop in
local HUD_EXIT = 0.3      -- s to shrink away at the end
local HUD_SETTLE = 20     -- frames at one rate before it counts

local function poseHud(self: VRScene, dt: number)
  self.hudShown = {}
  if dt > 0 then
    local hz = math.round(1 / dt)
    if hz == self.rateCandidate then
      self.rateRun += 1
    else
      self.rateCandidate, self.rateRun = hz, 1
    end
    if self.rateRun == HUD_SETTLE and hz ~= self.rateShown and hz >= 30 and hz <= 400 then
      if self.rateShown > 0 then
        self.hudTime = 0 -- not at startup, only on a change
      end
      self.rateShown = hz
    end
  end
  if self.hudTime < 0 then
    return
  end
  local time = self.hudTime + dt
  self.hudTime = if time > HUD_TIME then -1 else time
  if time > HUD_TIME or (num(self, 'eyeL_qw') == 0 and num(self, 'eyeL_qy') == 0) then
    return
  end
  local lx, ly, lz, hr = poseOf(self, 'eyeL_')
  local rx, ry, rz = poseOf(self, 'eyeR_')
  local cx, cy, cz = (lx + rx) / 2, (ly + ry) / 2, (lz + rz) / 2
  local pop = math.clamp(time / HUD_POP, 0, 1)
  local leave = math.clamp((time - (HUD_TIME - HUD_EXIT)) / HUD_EXIT, 0, 1)
  local scale = easeOutBack(pop) * (1 - leave * leave)
  if scale <= 0.001 then
    return
  end
  local text = tostring(self.rateShown)
  local span = (#text - 1) * 6
  for k = 1, math.min(#text, HUD_MAX) do
    local d = tonumber(string.sub(text, k, k)) :: number
    local along = ((k - 1) * 6 - span / 2) * HUD_PIXEL
    local model = poseModel(cx, cy, cz, hr,
      HUD_PIXEL * scale, HUD_PIXEL * scale, HUD_PIXEL * scale,
      along, -HUD_DROP, -HUD_DISTANCE)
    self.hudParts[k] = { model = model, r = HUD_COLOUR[1], g = HUD_COLOUR[2], b = HUD_COLOUR[3], mode = 0 }
    table.insert(self.hudShown, d + 1)
  end
end

-- Puts the head at the spawn point looking straight down the court,
-- whichever way we face in the room: once tracking starts, and on respawn.
local SPAWN_X, SPAWN_Z = 0, 0
local function alignRig(self: VRScene)
  if num(self, 'eyeL_qw') == 0 and num(self, 'eyeL_qy') == 0 then
    return -- no head pose yet
  end
  local hr = quatRows(num(self, 'eyeL_qx'), num(self, 'eyeL_qy'),
    num(self, 'eyeL_qz'), num(self, 'eyeL_qw'))
  self.rigYaw = -headYaw(hr)
  self.rigX, self.rigY, self.rigZ = 0, 0, 0
  local lx, _, lz = worldPoint(self, 'eyeL_')
  local rx, _, rz = worldPoint(self, 'eyeR_')
  self.rigX, self.rigZ = SPAWN_X - (lx + rx) / 2, SPAWN_Z - (lz + rz) / 2
  self.velX, self.velY, self.velZ = 0, 0, 0
  self.history = {}
  for _, hand in self.hands do
    hand.touching, hand.ready = false, false
  end
  self.aligned = true
end

function advance(self: VRScene, seconds: number): boolean
  if self.litShader == nil then
    return true -- init has not run (e.g. the Skin artboard input is unset)
  end
  if not self.aligned then
    alignRig(self)
  end
  locomote(self, seconds)
  publishPose(self)
  poseSelf(self, seconds)
  for slot = 1, REMOTE_SLOTS do
    poseMonke(self, slot, seconds)
  end
  poseTitle(self, seconds)
  poseHud(self, seconds)
  return true
end

-- ---------------------------------------------------------------- draw

type EyeDraws = { hands: { number }, remotes: { number }, labels: { number } }

-- Writes this eye's uniforms; returns which hands and remote players to draw.
local function prepareEye(self: VRScene, eye: Eye, prefix: string): EyeDraws
  local ex, ey, ez, er = poseOf(self, prefix .. '_')
  local proj = projection(
    num(self, prefix .. '_fovL'), num(self, prefix .. '_fovR'),
    num(self, prefix .. '_fovU'), num(self, prefix .. '_fovD'))
  if self.direct then
    -- Land upright in OpenXR's bottom-up image (see header).
    proj[6] = -proj[6]
    proj[10] = -proj[10]
  end
  local viewProj = mul(proj, viewFromPose(ex, ey, ez, er))

  local staging = self.staging
  local function writeDraw(ubo: GPUBuffer, model: { number },
                           r: number, g: number, b: number, mode: number)
    writeMat(staging, 0, viewProj)
    writeMat(staging, 64, model)
    buffer.writef32(staging, 128, r)
    buffer.writef32(staging, 132, g)
    buffer.writef32(staging, 136, b)
    buffer.writef32(staging, 140, 1)
    buffer.writef32(staging, 144, mode)
    buffer.writef32(staging, 148, 0)
    buffer.writef32(staging, 152, 0)
    buffer.writef32(staging, 156, 0)
    ubo:write(staging)
  end

  -- The level's vertices are already in world space and carry their own
  -- colour and material; it only needs this eye's viewProj.
  writeDraw(eye.ubos[1], IDENTITY, 0, 0, 0, 0)

  -- Our arms, posed in advance.
  local activeHands: { number } = {}
  for h = 1, 2 do
    local arm = self.selfArms[h]
    if arm then
      table.insert(activeHands, h)
      local base = LEVEL_DRAWS + (h - 1) * ARM_PARTS
      for i, part in arm do
        writeDraw(eye.ubos[base + i], part.model, part.r, part.g, part.b, part.mode)
      end
    end
  end

  -- Remote players: their monkes, posed once per frame in advance.
  local remotes: { number } = {}
  local labels: { number } = {}
  for slot, m in self.monkes do
    if m.key >= 0 then
      table.insert(remotes, slot)
      local base = LEVEL_DRAWS + CONTROLLER_DRAWS + (slot - 1) * REMOTE_DRAWS
      for i, part in m.parts do
        writeDraw(eye.ubos[base + i], part.model, part.r, part.g, part.b, part.mode)
      end
      -- Upright billboard aimed at the viewer; hidden at long range and very
      -- close range so the small name plate does not dominate the face.
      local c = PLAYER_COLOURS[m.key % #PLAYER_COLOURS + 1]
      local dx, dz = ex - m.x, ez - m.z
      local distance = math.sqrt(dx * dx + dz * dz)
      if distance > 0.35 and distance < 10 then
        table.insert(labels, slot)
        local nx, nz = dx / distance, dz / distance
        local model = {
          nz * 0.40, 0, -nx * 0.40, 0,
          0, 0.085, 0, 0,
          nx * 0.004, 0, nz * 0.004, 0,
          m.x, m.y + 0.27, m.z, 1,
        }
        -- Dark plate with a subtle player-colour tint; near-white lettering.
        writeDraw(eye.ubos[base + MONKE_PARTS + 1], model,
          0.094 + c[1] * 0.025, 0.141 + c[2] * 0.025, 0.165 + c[3] * 0.025, 2)
        writeDraw(eye.ubos[base + MONKE_PARTS + 2], model, 0.945, 0.961, 0.933, 2)
      end
    end
  end
  for _, i in self.titleShown do
    local part = self.titleParts[i]
    writeDraw(eye.ubos[TITLE_BASE + i], part.model, part.r, part.g, part.b, part.mode)
  end
  for k in self.hudShown do
    local part = self.hudParts[k]
    writeDraw(eye.ubos[HUD_BASE + k], part.model, part.r, part.g, part.b, part.mode)
  end
  return { hands = activeHands, remotes = remotes, labels = labels }
end

-- Issues one eye's draws into an open pass.
local function encodeEye(self: VRScene, pass: GPURenderPass, eye: Eye, d: EyeDraws)
  local activeHands = d.hands
  pass:setPipeline(self.levelPipeline :: GPUPipeline)
  pass:setBindGroup(0, eye.groups[1])
  pass:setBindGroup(1, self.shadowGroup :: GPUBindGroup)
  pass:setVertexBuffer(0, self.levelVerts :: GPUBuffer)
  pass:draw(self.levelCount)
  pass:setPipeline(self.pipeline :: GPUPipeline)
  pass:setBindGroup(1, self.skins[SELF_SKIN].group :: GPUBindGroup)
  pass:setVertexBuffer(0, self.cubeVerts :: GPUBuffer)
  for _, h in activeHands do
    for i = 1, ARM_PARTS do
      pass:setBindGroup(0, eye.groups[LEVEL_DRAWS + (h - 1) * ARM_PARTS + i])
      pass:draw(36)
    end
  end
  for _, slot in d.remotes do
    local base = LEVEL_DRAWS + CONTROLLER_DRAWS + (slot - 1) * REMOTE_DRAWS
    pass:setBindGroup(1, self.skins[slot].group :: GPUBindGroup)
    for i = 1, MONKE_PARTS do
      pass:setBindGroup(0, eye.groups[base + i])
      pass:draw(36)
    end
  end
  pass:setBindGroup(1, self.shadowGroup :: GPUBindGroup)
  for _, i in self.titleShown do
    pass:setVertexBuffer(0, self.titleLetters[i].verts)
    pass:setBindGroup(0, eye.groups[TITLE_BASE + i])
    pass:draw(self.titleLetters[i].count)
  end
  for _, slot in d.labels do
    local base = LEVEL_DRAWS + CONTROLLER_DRAWS + (slot - 1) * REMOTE_DRAWS
    local name = self.monkes[slot].key % #PLAYER_NAMES + 1
    pass:setVertexBuffer(0, self.cubeVerts :: GPUBuffer)
    pass:setBindGroup(0, eye.groups[base + MONKE_PARTS + 1])
    pass:draw(36)
    pass:setVertexBuffer(0, self.nameVerts[name])
    pass:setBindGroup(0, eye.groups[base + MONKE_PARTS + 2])
    pass:draw(self.nameCounts[name])
  end
  -- The rate readout is not in the shadow pass: it floats with the head.
  for k, d in self.hudShown do
    pass:setVertexBuffer(0, self.hudDigits[d].verts)
    pass:setBindGroup(0, eye.groups[HUD_BASE + k])
    pass:draw(self.hudDigits[d].count)
  end
end

-- The sun's depth pass: every solid that casts a shadow, using the first
-- eye's uniforms (the same models in both eyes). Name plates are skipped.
local function renderShadow(self: VRScene, target: GPUTarget, eye: Eye, d: EyeDraws)
  local pass = target:beginRenderPass({
    depthStencil = {
      view = self.shadowView :: GPUTextureView,
      depthLoadOp = 'clear',
      depthStoreOp = 'store',
      depthClearValue = 1,
    },
    label = 'sun-shadow',
  })
  pass:setPipeline(self.levelShadowPipeline :: GPUPipeline)
  pass:setBindGroup(0, eye.groups[1])
  pass:setBindGroup(1, self.shadowPassGroup :: GPUBindGroup)
  pass:setVertexBuffer(0, self.levelVerts :: GPUBuffer)
  pass:draw(self.levelCount)
  pass:setPipeline(self.shadowPipeline :: GPUPipeline)
  pass:setBindGroup(1, self.shadowPassGroup :: GPUBindGroup)
  pass:setVertexBuffer(0, self.cubeVerts :: GPUBuffer)
  for _, h in d.hands do
    for i = 1, ARM_PARTS do
      pass:setBindGroup(0, eye.groups[LEVEL_DRAWS + (h - 1) * ARM_PARTS + i])
      pass:draw(36)
    end
  end
  for _, slot in d.remotes do
    local base = LEVEL_DRAWS + CONTROLLER_DRAWS + (slot - 1) * REMOTE_DRAWS
    for i = 1, MONKE_PARTS do
      pass:setBindGroup(0, eye.groups[base + i])
      pass:draw(36)
    end
  end
  for _, i in self.titleShown do
    pass:setVertexBuffer(0, self.titleLetters[i].verts)
    pass:setBindGroup(0, eye.groups[TITLE_BASE + i])
    pass:draw(self.titleLetters[i].count)
  end
  pass:finish()
end

local CLEAR: GPUColor = { 0.53, 0.67, 0.68, 1 }

-- Canvas path: one pass per eye into its gpuCanvas.
local function renderEyeToCanvas(self: VRScene, eye: Eye, hands: EyeDraws, prefix: string)
  local canvas = eye.canvas :: GPUCanvas
  local msaa = eye.msaaView
  local pass = canvas:beginRenderPass({
    color = { {
      view = if msaa then msaa else canvas:colorView(),
      resolveTarget = if msaa then canvas:colorView() else nil,
      loadOp = 'clear',
      storeOp = if msaa then 'discard' else 'store',
      clearColor = CLEAR,
    } },
    depthStencil = {
      view = eye.depthView :: GPUTextureView,
      depthLoadOp = 'clear',
      depthStoreOp = 'discard',
      depthClearValue = 1,
    },
    label = prefix,
  })
  encodeEye(self, pass, eye, hands)
  pass:finish()
end

-- Direct path: both eyes in one pass, resolved into the host's target.
local function renderDirect(self: VRScene, target: GPUTarget, targetView: GPUTextureView)
  local w, h = self.width, self.height
  local hands = { prepareEye(self, self.eyes[1], 'eyeL'), prepareEye(self, self.eyes[2], 'eyeR') }
  renderShadow(self, target, self.eyes[1], hands[1])
  local msaa = self.directMsaa
  local pass = target:beginRenderPass({
    color = { {
      view = if msaa then msaa else targetView,
      resolveTarget = if msaa then targetView else nil,
      loadOp = 'clear',
      storeOp = if msaa then 'discard' else 'store',
      clearColor = CLEAR,
    } },
    depthStencil = {
      view = self.directDepth :: GPUTextureView,
      depthLoadOp = 'clear',
      depthStoreOp = 'discard',
      depthClearValue = 1,
    },
    label = 'eyes',
  })
  for e = 1, 2 do
    pass:setViewport((e - 1) * w, 0, w, h)
    pass:setScissorRect((e - 1) * w, 0, w, h)
    encodeEye(self, pass, self.eyes[e], hands[e])
  end
  pass:finish()
end

function draw(self: VRScene, renderer: Renderer)
  if self.litShader == nil or self.sampler == nil or self.context == nil then
    return
  end
  local w = math.floor(num(self, 'eyeWidth'))
  local h = math.floor(num(self, 'eyeHeight'))
  if w <= 0 or h <= 0 then
    return
  end
  local samples = math.floor(num(self, 'msaa'))
  if samples ~= 1 and samples ~= 2 and samples ~= 4 then
    samples = DEFAULT_SAMPLES
  end
  local target: GPUTarget? = nil
  if num(self, 'direct') > 0.5 then
    target = (self.context :: Context):gpuTarget()
    if target == nil and not self.warnedNoTarget then
      print('VRScene: direct path requested but the host exposes no target')
      self.warnedNoTarget = true
    end
  end
  local direct = target ~= nil
  local config = string.format('%d/%d/%d/%s', w, h, samples, tostring(direct))
  if config ~= self.config then
    configure(self, w, h, samples, direct)
    self.config = config
  end

  -- Every skin in use into its canvas; the eye passes sample them.
  for _, skin in self.skins do
    local instance = skin.instance
    if skin.active and instance then
      local skinRenderer = skin.canvas:beginFrame({ clearColor = 0 })
      instance:draw(skinRenderer)
      skin.canvas:endFrame()
    end
  end

  -- G4 probe: echo the frame index the host wrote this frame.
  local seen = self.props['seenFrame']
  if seen then
    seen.value = num(self, 'frameIndex')
  end

  if target then
    local view = target.view
    if view then
      renderDirect(self, target, view)
    end
    return
  end

  local left = prepareEye(self, self.eyes[1], 'eyeL')
  local right = prepareEye(self, self.eyes[2], 'eyeR')
  renderShadow(self, self.eyes[1].canvas :: GPUCanvas, self.eyes[1], left)
  renderEyeToCanvas(self, self.eyes[1], left, 'eyeL')
  renderEyeToCanvas(self, self.eyes[2], right, 'eyeR')
  local sampler = self.sampler :: ImageSampler
  renderer:drawImage((self.eyes[1].canvas :: GPUCanvas).image, sampler, 'srcOver', 1)
  renderer:save()
  renderer:transform(Mat2D.withTranslation(w, 0))
  renderer:drawImage((self.eyes[2].canvas :: GPUCanvas).image, sampler, 'srcOver', 1)
  renderer:restore()
end

return function(): Node<VRScene>
  return {
    nameVerts = {},
    nameCounts = {},
    props = {},
    eyes = {},
    litShader = nil,
    config = '',
    samples = DEFAULT_SAMPLES,
    direct = false,
    directMsaa = nil,
    directDepth = nil,
    warnedNoTarget = false,
    pipeline = nil,
    levelPipeline = nil,
    shadowPipeline = nil,
    levelShadowPipeline = nil,
    drawLayout = nil,
    shadowLayout = nil,
    shadowView = nil,
    shadowGroup = nil,
    skinArtboard = late(),
    skins = {},
    titleLetters = {},
    titleTime = -1,
    titleX = 0, titleY = 0, titleZ = 0, titleYaw = 0,
    titleParts = {},
    titleShown = {},
    hudDigits = {},
    rateCandidate = 0,
    rateRun = 0,
    rateShown = 0,
    hudTime = -1,
    hudParts = {},
    hudShown = {},
    shadowPassGroup = nil,
    lightViewProj = {},
    cubeVerts = nil,
    levelVerts = nil,
    levelCount = 0,
    sampler = nil,
    context = nil,
    width = 0,
    height = 0,
    staging = buffer.create(UBO_SIZE),
    rigX = 0, rigY = 0, rigZ = 0,
    rigYaw = 0,
    aligned = false,
    velX = 0, velY = 0, velZ = 0,
    hands = {
      { touching = false, ready = false, x = 0, y = 0, z = 0 },
      { touching = false, ready = false, x = 0, y = 0, z = 0 },
    },
    history = {},
    monkes = emptyMonkes(),
    selfYaw = nil,
    selfArms = {},
    init = init,
    advance = advance,
    draw = draw,
  }
end
