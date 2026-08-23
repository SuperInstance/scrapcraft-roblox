# SPEC — Pass 2: YardBuilder.luau + WorldModel.luau (worldgen port)

You are porting the Scrapcraft yard generator from JavaScript to Luau for Roblox.
**Read these files first — they are the source of truth, do NOT invent numbers:**

- Original worldgen (port this): `/home/eileen/projects/Scrapcraft/src/World.js`
- Block registry (already ported, USE IT): `src/shared/Blocks.luau`
- Config constants (already ported, USE IT): `src/shared/Config.luau`
- Seeded RNG (already ported, USE IT): `src/server/WorldGen/LCG.luau`
- Landmarks data: `/home/eileen/projects/Scrapcraft/src/data/landmarks.js` (BAND_FLAVOR + LANDMARKS)
- Plaques data: `/home/eileen/projects/Scrapcraft/src/data/plaques.js` (positions only in Phase 1)

## Deliverable 1: `src/server/WorldGen/YardBuilder.luau`

```lua
local YardBuilder = {}
-- Returns: { landmarks = {workbench={x=,z=}, ...}, partCount = n }
function YardBuilder.generate(parent: Instance, seed: number)
```

`parent` is a pre-made Folder in Workspace named "Scrapcraft". The function
creates the whole yard under it, deterministically from `seed` (42).

### Porting rules

1. **The RNG call sequence must match World.js exactly.** Use `LCG.new(seed)`
   and call `:next()` in the same order as World.js calls `rng()`. Where
   World.js writes `Math.floor(rng() * n)` use `math.floor(rng:next() * n)`.
   Do NOT skip or reorder random draws (the layout laws are the product of the
   sequence). The one exception below: ground layer (see "Ground" section).
2. Port `generate()` phase by phase in the SAME ORDER as World.js:
   ground → roads → band0 → band1 → band2 → band3 → buried caches →
   band flavor → landmarks (Phase 1: landmarks phase can be a no-op stub
   except where band generators already place stations).
3. Port band generators `_band0`..`_band3`, `_scrapCluster`, `_junkCar`,
   `_scatter`, `_buildShed`, and the oval ring loop — with the SAME counts
   (30/40 clusters, 18 towers, 10 refineries, 4 forge sheds, 6 scrap walls,
   8 crate warehouses, 5 electronics buildings, 80 chaos stacks, 18 junk
   cars, 12 ruins, crystal seed list, etc.) and the SAME rng() call shapes.
4. Skip in Phase 1 (document with `-- PHASE 2:` comments, keep the rng draws
   that precede them untouched): nothing in bands 0–3 except where noted:
   - `_placeLandmarks()` named landmarks — stub (return empty).
   - PLAQUES block placement in band3 — skip, but you may keep the loop if
     trivially portable; simplest: skip with a comment.
5. **Ground simplification (DECIDED, see docs/PORT-ARCHITECTURE.md):** the
   per-cell ground layer (16,384 draws of rng) and `_bandFlavor` are replaced
   by: one 512x512-stud ground slab Part (smooth gray-green, top at Y=0,
   Anchored) + four band tint strips (thin 0.2-stud parts at Y=0.01, one per
   band, subtle tint from yard-bible band colors: #8B6914, #707070, #228822,
   #882222 at low transparency ~0.7) + 3 road strips (concrete #888880,
   3 cells wide = 12 studs, running the full 512 studs of Z, at roads x=8,
   x=64, x=120). CRITICAL: since we skip the ground draw loop, the rng
   sequence no longer matches World.js exactly — accept this, but then
   re-seed a FRESH `LCG.new(seed + 1)` for everything AFTER the ground loop
   would have run, and note it in a comment. Determinism within the port is
   what matters now.
6. **Block parts** (everything at level ≥ 1): one Part per block, size
   `Config.CELL x Config.CELL x Config.CELL` (4x4x4), positioned via
   `Config.cellToStud` + `Config.levelToStudY`. Properties:
   - Anchored = true, CanCollide = solid per `Blocks.isSolid` (hazard
     puddles/slag nonSolid → CanCollide false), Material = Metal for metal
     ids (RUST_METAL, CLEAN_METAL, WALL_METAL, ROOF_METAL, SCRAP_CANNON),
     Wood for WOOD_PLANK/CRATE, Plastic for the rest. Color from
     `Blocks.DEF[id].color`.
   - Emissive-looking blocks (TRACK, FLOODLIGHT, CRYSTAL_ORE, BEACON,
     ACID_PUDDLE, HOT_SLAG, stations): add a `PointLight` (small, from
     emissive color) only for FLOODLIGHT/BEACON/CRYSTAL_ORE to cap light
     count; others just get brighter Color3 (lerp 30% toward white).
   - CollectionService tag `"Block"` on every block part. Tag `"Mineable"`
     additionally when `Blocks.isMineable(id)`. Attributes: `BlockId`=id,
     `X`=x, `Z`=z, `Level`=level (integers).
   - Name = Blocks.DEF[id].name.
   - Stations (WORKBENCH/FORGE/SMELTER) also get tag `"Station"` and
     attribute `Station` = def.station. These are placed by band generators
     via setBlock like the original (12,1,8 workbench etc.) — they are blocks
     too (give them a distinct slightly-emissive look per rule above).
   - Special-case placement: WORKBENCH/FORGE/SMELTER parts are 4x3x4
     (slightly squat) — cosmetic only, still occupy the cell.
7. **Structure:** blocks parent under `parent.Blocks` (Folder); the ground
   slab/strips under `parent.Ground`. Count parts, return in result table.
   Keep a `YardBuilder._setBlock(x, level, z, id)` internal honoring the
   original's overwrite semantics (later writes win, except interactive
   stations should NOT be overwritten by later scatter — see World.js `_lm`
   guard; implement a simple guard: never overwrite WORKBENCH/FORGE/SMELTER/
   BEACON/TRACK/BURIED_CACHE with a non-station id... simpler faithful rule:
   skip write if current block is a station or BEACON/TRACK/BURIED_CACHE).
8. **The oval** (band 2): the original samples 360 angles and does
   `Math.round` on offsets — port exactly (loop i=0..359, rad=i*math.pi/180,
   ox=math.round(oCx+oRx*math.cos(rad)), oz=math.round(oCz+oRz*math.sin(rad)),
   bounds check, setBlock TRACK at level 1 but as a FLAT part: size
   4x0.4x4, Y at 0.2 — track is ground-level marking, CanCollide false,
   still tagged Block+Mineable).
   ALSO draw 4 floodlight towers at the oval's cardinal points (cx±rx+2,
   cz±(rz+2)-ish: use (21,84),(49,84),(35,76),(35,92) — 6-tall WALL_METAL
   column + FLOODLIGHT block on top) — this is the floodlit oval from the
   bible; mark the comment as a Roblox-side addition.
9. **Earl's gate at spawn**: original spawn is around (8, 4)-ish (roads at
   x=8). Phase 1 Roblox: build a simple gate arch AT THE YARD GATE band
   across the x=8 road at z=3: two WALL_METAL pylons at cells (6, 3) and
   (10, 3), 4 tall, with a WOOD_PLANK crossbar row at level 4 between them,
   plus a BEACON on each pylon top. Comment: "Earl's gate — bible: EARL'S
   SALVAGE & SCRAP, EST. WHENEVER". Roblox-side addition, documented.
10. **Spawn point**: create a SpawnLocation at cell (8, 5) center (use
    Config.cellToStud), size 4x1x4, top at Y=0.5, transparent-ish concrete,
    under `parent`. Place it BEFORE band0 scatter so nothing traps spawn:
    simplest — after generation, clear (destroy) any block parts occupying
    cells (7..9, 4..6) — do that, with a comment.
11. Code style: `--!strict` at top (use `any` where the type system fights
    you, prefer typed). NO shell calls, NO os/io. Pure Luau + Roblox API.
    Every nontrivial port decision gets a short comment citing the original
    line (e.g. `-- World.js L~120: 30 clusters`).

## Deliverable 2: `src/server/Systems/WorldModel.luau`

The yard's logical model AFTER generation — the bot's physics oracle.

```lua
local WorldModel = {}
function WorldModel.init()                    -- call after YardBuilder.generate
function WorldModel.setSolid(x, z, level, id) -- sync on block add/remove
function WorldModel.isSolidAt(x: number, z: number): boolean
    -- floor(x), LEVEL 1 ONLY (bots roll on the ground), true if solid block
    -- (GameWorldAdapter.js isSolidAt: world.isSolidAt(floor(x), 1, floor(z)))
function WorldModel.distanceAhead(x, z, heading): number
    -- GameWorldAdapter.js distanceAhead: 24-step ray, range SONAR_RANGE,
    -- raw = max(0, (t - 0.25) / range) on first hit else 1. No weather noise
    -- in Phase 1 (comment it).
function WorldModel.removeBlock(x, z, level)  -- mining calls this
function WorldModel.getSpawn(): (number, number) -- bot spawn near bench
```

Implementation: a 128x128 grid (level-1 occupancy, boolean array [z*128+x]).
`YardBuilder` should expose what blocks exist — cleanest: WorldModel.init
takes the same data YardBuilder kept: have YardBuilder.generate return
`{ landmarks = ..., level1 = <the 128x128 array of level-1 block ids> }` and
WorldModel.init(level1Array) copies it. When a mineable block is removed
(MiningService → WorldModel.removeBlock), also destroy the Part (keep a
lookup `partAt[z*128+x]` for level-1 mineables inside WorldModel; blocks
above level 1 that fall... Phase 1: when a level-L block is mined, blocks
above it do NOT fall (comment: PHASE 2 gravity pass) — but WorldModel only
tracks level 1 anyway).

Bench/bot spawn: expose `landmarks.workbench` yard-coords; BotService will
place the bot 2 cells south of the workbench.

## Also update

`src/server/init.server.luau` — bootstrap: require WorldGen.YardBuilder +
Systems.WorldModel, generate into workspace.Scrapcraft folder (create if
missing), then `print(("[scrapcraft] yard generated: %d parts, workbench @ %d,%d")`).
Leave TODO comments for MiningService/BotService wiring (Pass 3/4 adds them).

## Testing

After writing: run `/usr/bin/lua5.1 -p <file>` on each new .luau (syntax
check only — Roblox APIs won't run, that's fine; note any Luau-only syntax
you had to avoid for 5.1 compat, e.g. no `continue`, no compound `+=`).
Report: files written, rng-order decisions, anything you could not port 1:1.
