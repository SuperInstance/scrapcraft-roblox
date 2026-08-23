# SPEC — Pass 3: BrainVM.luau + BotService.luau (the bot that proves the port breathes)

Read first — source of truth, port real numbers, no guessing:

- `src/shared/Config.luau` (kinematics constants), `src/shared/TileProgram.luau`
  (program data + starter brains), `src/shared/Blocks.luau`, `src/shared/Items.luau`
- ORIGINAL sim (port these semantics):
  - `/home/eileen/projects/Scrapcraft/src/maker/VirtualRobot.js` (whole file)
  - `/home/eileen/projects/Scrapcraft/src/maker/kinematics.js` (whole file)
  - `/home/eileen/projects/Scrapcraft/src/maker/TileVM.js` — READ for the
    execution model (coroutine stepping, wait handling). We port a SUBSET.
  - `/home/eileen/projects/Scrapcraft/src/maker/primitives.js` — only the
    `drive`, `turn`, `beep`, `led` primitives' semantics.
  - `/home/eileen/projects/Scrapcraft/src/ScrapBot.js` — battery + mesh
    proportions (constructor `_buildMesh`) + `setBrain`.
- WorldModel API (exists from Pass 2): `WorldModel.isSolidAt(x, z)` and
  `WorldModel.distanceAhead(x, z, heading)` — these ARE the
  GameWorldAdapter for Phase 1. Do not modify them.

## Deliverable 1 — `src/server/Systems/BrainVM.luau`

A server-side tile-program VM driving a VirtualRobot, ported exactly.

```lua
local BrainVM = {}
function BrainVM.new(program, spawnState: {x: number, z: number, heading: number})
    -- returns runtime { robot = VirtualRobot-like, step(dt), errors = {} }
```

### VirtualRobot port (VirtualRobot.js, exact):

- State: `x, z` (yard units, floats), `heading` (radians, 0 = +Z),
  `drivePower, turnPower ∈ [-1,1]`, `led`.
- `tick(dt)`:
  - If turnPower ≠ 0: `heading += turnPower * Config.TURN_RATE * (pi/180) * dt`,
    wrap to [-π, π] exactly like the original (subtract/add 2π).
  - If drivePower ≠ 0: `dist = drivePower * Config.DRIVE_SPEED * dt`;
    `nx = x + sin(heading)*dist`, `nz = z + cos(heading)*dist`;
    **axis-separated slide**: `if not blocked(nx, z) then x = nx`,
    `if not blocked(x, nz) then z = nz` (note: second check uses UPDATED x).
  - `blocked(x, z)` samples 4 points at BOT_RADIUS offsets:
    isSolidAt(x±r, z) or isSolidAt(x, z±r) — port `blocked()` verbatim.

### VM subset (TileVM.js execution model, node types: forever, if_else,
action, wait):

- Stepped execution, NOT a coroutine per program — implement as a small
  interpreter with a program counter + frame stack that processes for at
  most ~dt seconds of virtual time per `step(dt)` call... SIMPLER (Phase 1):
  actions are INSTANT state sets on the robot (drive sets drivePower;
  turn sets turnPower for `seconds`? NO — original `turn` primitive with
  dir+speed just sets turnPower continuously; the Wall Avoider relies on
  `turn right 0.6; wait 0.4` = turn for 0.4s then fall through to re-check).
  So: `action drive {dir, speed}` → setDrive(±speed) AND setTurn(0) (check
  primitives.js for whether drive zeroes turn — follow what primitives.js
  actually does; if drive doesn't zero turn, don't). `action turn {dir,
  speed}` → setTurn(±speed) (and drive zeroing per primitives.js).
  `action beep` → fire an event `{kind="beep"}`; `action led` → event.
- Execution: evaluate node list; `forever` loops (frame stack);
  `if_else` evaluates cond against sensors; `wait s` pauses THAT program's
  execution for s virtual seconds (runtime has waitTimer; step(dt) first
  consumes waitTimer, then continues tree from where it left off).
  Re-check conditions each loop iteration (like the JS VM does per tick).
- Condition eval: sensor "distance_ahead" → `WorldModel.distanceAhead(
  robot.x, robot.z, robot.heading)`; cmp ops lt/gt/lte/gte/eq/neq/is.
- `step(dt)`: advance interpreter (with the wait semantics), then
  `robot:tick(dt)`. Battery/anim NOT here (BotService does battery).
- Errors: unknown prim/node → push to `errors` and halt (runtime.dead=true).

## Deliverable 2 — `src/server/Systems/BotService.luau`

### Model (port ScrapBot.js `_buildMesh` proportions; 1 yard unit = Config.CELL studs; bot total height ≈ 1.9 units ≈ 7.6 studs):

Build a Model "ScrapBot" from Parts (front of the bot = Roblox −Z face so
`CFrame.lookAt(pos, pos + forward)` shows the face; forward = (sin h, 0, cos h)):

- body: 0.5 x 0.55 x 0.35 units → studs 2.0 x 2.2 x 1.4, color edition
  bodyColor (gate edition: rusty orange 0xB07030-ish — check
  data/botEditions.js for gate bodyColor/speedMult/batteryDrainMult REAL
  values and use them), center Y at 0.8 units → 3.2 studs.
- head 0.38x0.35x0.35 u at y 1.25 u; eyes: two small parts (0.08 u cubes)
  cyan emissive on the FRONT (−Z) face; antenna + red tip at top;
- arms 0.15x0.45x0.15 u at x ±0.35 u, y 0.72 u; legs 0.16x0.35x0.16 u at
  x ±0.15 u, y 0.28 u. All parts Anchored, welded? NO — Anchored and the
  MODEL is moved by setting a root part CFrame every tick + other parts via
  WeldConstraints to a root "HumanoidRoot"-like part. Cleanest: build parts
  positioned relative to root, add WeldConstraint from each to root, then
  move only root.CFrame per tick.
- PrimaryPart = body part. Name model "ScrapBot".
- A small PointLight cyan on the head (glow, matches _glowLight 0.8 intensity).

### Spawning & ownership

- `BotService.init(worldModel, landmarks)`: on FIRST player join (or
  PlayerAdded), spawn ONE yard bot near the bench: 2 cells south of
  `landmarks.workbench` (cellToStud + heading π (facing +Z? pick facing the
  bench)), if occupied use (wb.x+2, wb.z+2). One bot per SERVER (Phase 1 —
  shared yard bot; comment: per-player bots Phase 2).
- Attach a ProximityPrompt to the bot body: "Attach Parts" (Phase 1 single
  prompt; MaxActivationDistance 10).

### Attach + brain flow (RemoteEvent `ScrapcraftBot` + InventoryService from parallel pass — require `script.Parent.InventoryService`; API: `.has(player,id,qty)`, `.consume(player,id,qty)`, `.add`):

- On prompt triggered by player:
  1. If no ultrasonic module attached and player has `ultrasonic_module` x1
     → consume, mark attached (attribute on model "Module"="ultrasonic"),
     tell client `{type="status", msg="📡 Ultrasonic module attached"}`.
  2. Else if no brain and player has `tin_brain` x1 → consume, LOAD BRAIN:
     `runtime = BrainVM.new(TileProgram.STARTER_WALL_AVOIDER,
       {x=bot.x, z=bot.z, heading=bot.heading})`, battery = 100,
     status "🧠 Brain loaded: Wall Avoider — look at it go".
  3. Else status message hinting what's missing.
- RemoteEvent `ScrapcraftBot` client→server `{type="clear"}`: stop brain
  (bot idles in place), used by a client stop button (stub ok).

### The tick loop (RunService.Heartbeat server-side):

- If runtime exists: battery drain per ScrapBot.js: driving =
  |drivePower| > 0.08 → drain `Config.BATT_DRAIN_DRIVE` else
  `Config.BATT_DRAIN_IDLE` (%/s), times gate edition batteryDrainMult
  (botEditions.js — real value). battery ≤ 0 → clear brain, status
  "🔋 battery depleted — Phase 2: charging pads". battery ≤ 15 warn once.
- `runtime.step(dt)`; then set root CFrame from robot pose:
  `sx, sz = Config.cellToStud(robot.x, robot.z)`… careful: cellToStud takes
  CELL centers — for FLOAT positions compute directly:
  `sx = Config.MAP_ORIGIN + robot.x * Config.CELL + Config.CELL/2` (same
  formula), `sy = Config.CELL/2` (roll on ground), CFrame.lookAt(
  Vector3.new(sx, sy, sz), Vector3.new(sx, sy, sz) + Vector3.new(
  sin(heading), 0, cos(heading))).
- Walk-cycle: swing leg/arm parts ±0.4 rad via sin(time*12) when moving —
  legs pivot at hip: cheap version = rotate leg parts CFrame offset —
  SKIP if fiddly; a gentle whole-model bob (±0.15 stud) is acceptable
  Phase 1 (comment which you chose).
- Beep events: throttle 1/2s; play nothing server-side — status toast to
  all clients `{type="status", msg="[BEEP]"}` is enough (comment: audio pass
  later). Actually better: attach Sound to head ("rbxassetid://" beep —
  do NOT guess asset ids; use `Instance.new("Sound")` with no id → silent
  stub comment).

### botEditions.js

Read `/home/eileen/projects/Scrapcraft/src/data/botEditions.js` for the gate
edition's REAL numbers (speedMult, batteryDrainMult, bodyColor). Apply
speedMult at… the ORIGINAL applies it in follow mode only (`BOT_SPEED *
edition.speedMult`); brain mode speed is kinematics.js pure. Follow that.

## Integration

Update `src/server/init.server.luau`: after MiningService init,
`BotService.init(WorldModel, yard.landmarks)` (guard: the file is written by
the parallel pass — MERGE, don't clobber; add your line after theirs).

## Verify

`/usr/bin/lua5.1 -p` every file you wrote (syntax gate; note Luau-vs-5.1
exceptions). Print `PASS3-DONE` + summary (what's real, what's stubbed).
