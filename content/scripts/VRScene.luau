-- VRScene: a Gorilla Tag style playground rendered entirely by Rive. The
-- native host writes eye poses, controller poses and triggers into the XR
-- ViewModel; this script moves the body (see locomotion), then renders the
-- level, controllers and rays once per eye.
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
local UBO_SIZE = 160 -- mat4 viewProj, mat4 model, vec4 color, vec4 params

local BOX_SIZE: { number } = { 0.05, 0.04, 0.12 }
local RAY_WIDTH = 0.003
local RAY_LENGTH = 1.5

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
}

-- A playground to climb and jump around on: steps, towers, pillars, a back
-- wall and a floating bridge. Boxes are axis aligned, so they double as
-- colliders. box(x, z, w, h, d) stands on the floor; base lifts it.
local function box(x: number, z: number, w: number, h: number, d: number,
                   r: number, g: number, b: number, base: number?): Obj
  local y0 = base or 0
  return { mesh = 'cube', x = x, y = y0 + h / 2, z = z, sx = w, sy = h, sz = d, r = r, g = g, b = b }
end

local OBJECTS: { Obj } = {
  { mesh = 'floor', x = 0, y = 0, z = 0, sx = 15, sy = 1, sz = 15, r = 0.09, g = 0.1, b = 0.13 },
  box(1.7, -1.8, 1.2, 0.6, 1.2, 0.95, 0.55, 0.25),
  box(3.2, -3.0, 1.2, 1.2, 1.2, 0.9, 0.4, 0.35),
  box(4.6, -4.6, 1.2, 1.9, 1.2, 0.8, 0.3, 0.45),
  box(2.6, -6.4, 1.4, 2.7, 1.4, 0.6, 0.35, 0.75),
  box(-1.9, -2.6, 2.0, 0.4, 2.0, 0.3, 0.7, 0.9),
  box(-3.6, -4.0, 1.6, 1.0, 1.6, 0.25, 0.55, 0.85),
  box(-2.2, -6.0, 1.2, 1.8, 1.2, 0.35, 0.8, 0.6),
  box(0.2, -8.2, 8.0, 3.4, 0.5, 0.45, 0.5, 0.6),
  box(0.2, -6.3, 3.4, 0.25, 0.8, 0.95, 0.8, 0.3, 2.5),
  box(-5.6, -1.2, 0.5, 2.6, 0.5, 0.55, 0.85, 0.45),
  box(5.8, -1.4, 0.5, 2.6, 0.5, 0.55, 0.85, 0.45),
  box(0.0, 3.5, 3.0, 0.9, 1.2, 0.85, 0.75, 0.5),
}
local CONTROLLER_DRAWS = 4 -- box L, ray L, box R, ray R

-- Multiplayer: the host broadcasts our head and hands on the local network
-- and writes up to REMOTE_SLOTS other players (already interpolated) into
-- the XR ViewModel. Each is drawn as a coloured head with a visor and two
-- hand cubes.
local REMOTE_SLOTS = 4
local REMOTE_DRAWS = 4 -- head, visor, hand L, hand R
local HEAD_SIZE: { number } = { 0.2, 0.2, 0.22 }
local VISOR_SIZE: { number } = { 0.16, 0.06, 0.03 }
local REMOTE_HAND_SIZE = 0.08
local PLAYER_COLOURS: { { number } } = {
  { 0.95, 0.45, 0.25 }, { 0.3, 0.75, 0.95 }, { 0.6, 0.9, 0.35 }, { 0.95, 0.8, 0.25 },
  { 0.85, 0.4, 0.85 }, { 0.35, 0.9, 0.75 }, { 0.95, 0.55, 0.6 }, { 0.6, 0.6, 0.95 },
}
local POSE_KEYS: { string } = { 'px', 'py', 'pz', 'qx', 'qy', 'qz', 'qw' }

type Hand = { touching: boolean, ready: boolean, x: number, y: number, z: number }

type VRScene = {
  props: { [string]: Property<number> },
  eyes: { Eye },
  litShader: Shader?,
  config: string,               -- current w/h/samples/path, rebuild on change
  samples: number,
  direct: boolean,
  directMsaa: GPUTextureView?,  -- direct path: 2W x H, nil when msaa = 1
  directDepth: GPUTextureView?,
  warnedNoTarget: boolean,
  pipeline: GPUPipeline?,
  cubeVerts: GPUBuffer?,
  floorVerts: GPUBuffer?,
  sampler: ImageSampler?,
  context: Context?,
  width: number,
  height: number,
  staging: buffer,
  -- Locomotion: the rig is where the play space sits in the world.
  rigX: number, rigY: number, rigZ: number,
  velX: number, velY: number, velZ: number,
  hands: { Hand },
  history: { { number } }, -- recent body velocities: vx, vy, vz
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

local function boxModel(x: number, y: number, z: number, sx: number, sy: number, sz: number): { number }
  return {
    sx, 0, 0, 0,
    0, sy, 0, 0,
    0, 0, sz, 0,
    x, y, z, 1,
  }
end

-- ---------------------------------------------------------------- state

local function num(self: VRScene, name: string): number
  local p = self.props[name]
  return if p then p.value else 0
end

-- World pose of a tracked thing: its play-space pose shifted by the rig.
local function poseOf(self: VRScene, prefix: string): (number, number, number, { { number } })
  return self.rigX + num(self, prefix .. 'px'), self.rigY + num(self, prefix .. 'py'),
    self.rigZ + num(self, prefix .. 'pz'),
    quatRows(num(self, prefix .. 'qx'), num(self, prefix .. 'qy'),
             num(self, prefix .. 'qz'), num(self, prefix .. 'qw'))
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
  if o.mesh == 'cube' then
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
    local tx = self.rigX + num(self, g .. 'px')
    local ty = self.rigY + num(self, g .. 'py')
    local tz = self.rigZ + num(self, g .. 'pz')
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
  local hx = self.rigX + num(self, 'eyeL_px')
  local hy = self.rigY + num(self, 'eyeL_py')
  local hz = self.rigZ + num(self, 'eyeL_pz')
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

  -- Fell out of the world: back to the start.
  if self.rigY < -30 then
    self.rigX, self.rigY, self.rigZ = 0, 0, 0
    self.velX, self.velY, self.velZ = 0, 0, 0
    self.history = {}
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
  local pipeline = self.pipeline :: GPUPipeline
  for _ = 1, #OBJECTS + CONTROLLER_DRAWS + REMOTE_SLOTS * REMOTE_DRAWS do
    local ubo = GPUBuffer.new({ size = UBO_SIZE, usage = 'uniform' })
    table.insert(eye.ubos, ubo)
    table.insert(eye.groups, GPUBindGroup.new({
      layout = pipeline:getBindGroupLayout(0),
      ubos = { { slot = 0, buffer = ubo } },
    }))
  end
  return eye
end

-- The pipeline depends on the sample count and, for the direct path, flipped
-- culling; rebuilt whenever either changes.
local function buildPipelines(self: VRScene, samples: number, cull: CullMode)
  local lit = self.litShader :: Shader
  self.pipeline = GPUPipeline.new({
    vertex = { module = lit, entryPoint = 'vs' },
    fragment = { module = lit, entryPoint = 'fs' },
    vertexLayout = { {
      stride = 24,
      attributes = {
        { format = 'float32x3', slot = 0, offset = 0 },
        { format = 'float32x3', slot = 1, offset = 12 },
      },
    } },
    colorTargets = { { format = 'rgba8unorm' } },
    depthStencil = { format = DEPTH_FORMAT, compare = 'less', write = true },
    cullMode = cull,
    sampleCount = samples,
  })
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
  self.litShader = shader
  self.cubeVerts = vertexBuffer(cubeData())
  self.floorVerts = vertexBuffer(floorData())
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
    for _, k in { 'qx', 'qy', 'qz', 'qw' } do
      setNum(self, part .. '_' .. k, num(self, q .. k))
    end
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

function advance(self: VRScene, seconds: number): boolean
  locomote(self, seconds)
  publishPose(self)
  return true
end

-- ---------------------------------------------------------------- draw

local function writeMat(b: buffer, offset: number, m: { number })
  for i = 1, 16 do
    buffer.writef32(b, offset + (i - 1) * 4, m[i])
  end
end

type EyeDraws = { hands: { number }, remotes: { number } }

local function remotePose(self: VRScene, prefix: string): (number, number, number, { { number } })
  return num(self, prefix .. 'px'), num(self, prefix .. 'py'), num(self, prefix .. 'pz'),
    quatRows(num(self, prefix .. 'qx'), num(self, prefix .. 'qy'),
             num(self, prefix .. 'qz'), num(self, prefix .. 'qw'))
end

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

  for i, o in OBJECTS do
    writeDraw(eye.ubos[i], boxModel(o.x, o.y, o.z, o.sx, o.sy, o.sz),
      o.r, o.g, o.b, if o.mesh == 'floor' then 1 else 0)
  end

  -- Controllers: a box at the grip (where it touches, while touching) and a
  -- ray along the aim.
  local activeHands: { number } = {}
  for h, hand in { 'L', 'R' } do
    if num(self, 'active' .. hand) > 0.5 then
      table.insert(activeHands, h)
      local t = math.clamp(num(self, 'trigger' .. hand), 0, 1)
      local gx, gy, gz, gr = poseOf(self, 'grip' .. hand .. '_')
      local handState = self.hands[h]
      if handState.touching then
        gx, gy, gz = handState.x, handState.y, handState.z
      end
      local ax, ay, az, ar = poseOf(self, 'aim' .. hand .. '_')
      local base = #OBJECTS + (h - 1) * 2
      writeDraw(eye.ubos[base + 1],
        poseModel(gx, gy, gz, gr, BOX_SIZE[1], BOX_SIZE[2], BOX_SIZE[3], 0, 0, 0),
        0.55 + 0.4 * t, 0.57 + 0.03 * t, 0.62 - 0.42 * t, 0)
      writeDraw(eye.ubos[base + 2],
        poseModel(ax, ay, az, ar, RAY_WIDTH, RAY_WIDTH, RAY_LENGTH, 0, 0, -RAY_LENGTH / 2),
        0.45 + 0.55 * t, 0.75 + 0.25 * t, 1, 2)
    end
  end

  -- Remote players: head + visor + hands, coloured by their id.
  local remotes: { number } = {}
  for slot = 1, REMOTE_SLOTS do
    local p = 'p' .. slot .. '_'
    if num(self, p .. 'active') > 0.5 then
      table.insert(remotes, slot)
      local c = PLAYER_COLOURS[math.floor(num(self, p .. 'color')) % #PLAYER_COLOURS + 1]
      local base = #OBJECTS + CONTROLLER_DRAWS + (slot - 1) * REMOTE_DRAWS
      local hx, hy, hz, hr = remotePose(self, p .. 'head_')
      writeDraw(eye.ubos[base + 1],
        poseModel(hx, hy, hz, hr, HEAD_SIZE[1], HEAD_SIZE[2], HEAD_SIZE[3], 0, 0, 0),
        c[1], c[2], c[3], 0)
      writeDraw(eye.ubos[base + 2],
        poseModel(hx, hy, hz, hr, VISOR_SIZE[1], VISOR_SIZE[2], VISOR_SIZE[3], 0, 0.02, -0.11),
        0.06, 0.07, 0.09, 0)
      for i, part in { 'handL_', 'handR_' } do
        local x, y, z, r = remotePose(self, p .. part)
        writeDraw(eye.ubos[base + 2 + i],
          poseModel(x, y, z, r, REMOTE_HAND_SIZE, REMOTE_HAND_SIZE, REMOTE_HAND_SIZE, 0, 0, 0),
          c[1] * 0.8, c[2] * 0.8, c[3] * 0.8, 0)
      end
    end
  end
  return { hands = activeHands, remotes = remotes }
end

-- Issues one eye's draws into an open pass.
local function encodeEye(self: VRScene, pass: GPURenderPass, eye: Eye, d: EyeDraws)
  local activeHands = d.hands
  pass:setPipeline(self.pipeline :: GPUPipeline)
  for i, o in OBJECTS do
    pass:setBindGroup(0, eye.groups[i])
    if o.mesh == 'floor' then
      pass:setVertexBuffer(0, self.floorVerts :: GPUBuffer)
      pass:draw(6)
    else
      pass:setVertexBuffer(0, self.cubeVerts :: GPUBuffer)
      pass:draw(36)
    end
  end
  pass:setVertexBuffer(0, self.cubeVerts :: GPUBuffer)
  for _, h in activeHands do
    pass:setBindGroup(0, eye.groups[#OBJECTS + (h - 1) * 2 + 1])
    pass:draw(36)
    pass:setBindGroup(0, eye.groups[#OBJECTS + (h - 1) * 2 + 2])
    pass:draw(36)
  end
  for _, slot in d.remotes do
    local base = #OBJECTS + CONTROLLER_DRAWS + (slot - 1) * REMOTE_DRAWS
    for i = 1, REMOTE_DRAWS do
      pass:setBindGroup(0, eye.groups[base + i])
      pass:draw(36)
    end
  end
end

local CLEAR: GPUColor = { 0.04, 0.05, 0.08, 1 }

-- Canvas path: one pass per eye into its gpuCanvas.
local function renderEyeToCanvas(self: VRScene, eye: Eye, prefix: string)
  local hands = prepareEye(self, eye, prefix)
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

  renderEyeToCanvas(self, self.eyes[1], 'eyeL')
  renderEyeToCanvas(self, self.eyes[2], 'eyeR')
  local sampler = self.sampler :: ImageSampler
  renderer:drawImage((self.eyes[1].canvas :: GPUCanvas).image, sampler, 'srcOver', 1)
  renderer:save()
  renderer:transform(Mat2D.withTranslation(w, 0))
  renderer:drawImage((self.eyes[2].canvas :: GPUCanvas).image, sampler, 'srcOver', 1)
  renderer:restore()
end

return function(): Node<VRScene>
  return {
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
    cubeVerts = nil,
    floorVerts = nil,
    sampler = nil,
    context = nil,
    width = 0,
    height = 0,
    staging = buffer.create(UBO_SIZE),
    rigX = 0, rigY = 0, rigZ = 0,
    velX = 0, velY = 0, velZ = 0,
    hands = {
      { touching = false, ready = false, x = 0, y = 0, z = 0 },
      { touching = false, ready = false, x = 0, y = 0, z = 0 },
    },
    history = {},
    init = init,
    advance = advance,
    draw = draw,
  }
end
