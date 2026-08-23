# Scrapcraft — Roblox Port Architecture

The yard, ported from the three.js voxel original (`/home/eileen/projects/Scrapcraft`)
to Roblox Studio via Rojo. Lore/geography canon: `/home/eileen/projects/scrapcraft-world/worldbible/`
(the "port bible"). Every tuning number in this port is **extracted from the original
source**, never guessed. Extraction provenance is noted per-module.

## Phase 0 decision — sync tooling: ROJO

- `default.project.json` is a **Rojo 7 project file** (repo root). `rojo` 7.5.1 is
  installed **in WSL** at `~/.cargo/bin/rojo`.
- Argon (`~/.argon/bin/argon.exe`, Windows-side) remains the *alternative* live-sync
  path (see README "Fallback: Argon"), but Phase 0 committed to the Rojo project file
  as source of truth. Argon is plugin+CLI watch; Rojo is the industry-standard
  bidirectional sync with a declarative project tree. We use **Rojo serve** from WSL;
  Windows reaches WSL2 services on `localhost` out of the box.
- See README.md § "The developer loop" for the exact commands.

## Repo layout (Rojo)

```
default.project.json      Rojo 7 project (maps src/ → DataModel)
src/
  shared/                 ReplicatedStorage.Shared  — pure data + constants
    Config.luau           global constants (map size, seed, CELL, day cycle)
    Blocks.luau           block IDs, colors, hardness, drops — extracted
    Items.luau            item definitions — extracted subset
    Recipes.luau          crafting recipes — extracted subset (real numbers)
    TileProgram.luau      tile-program data model + STARTER brains (ported)
  server/                 ServerScriptService.Server
    init.server.luau      bootstrap: worldgen → services
    WorldGen/
      LCG.luau            seeded RNG, bit-exact port of the original LCG
      YardBuilder.luau    the yard: bands, roads, oval, stations, stacks
    Systems/
      WorldModel.luau     occupancy grid + sonar raycast (bot physics queries)
      MiningService.luau  hold-to-mine, hardness, drops, lucky finds
      InventoryService.luau
      CraftingService.luau
      BotService.luau     spawn bot, attach parts, load brains
      BrainVM.luau        VirtualRobot + tile-VM subset port
      DayNightService.luau  360 s day, night drop bonus
  client/                 StarterPlayerScripts.Client
    init.client.luau
    MiningClient.luau     raycast targeting + hold-to-mine + progress UI
    InventoryUI.luau      inventory stub (ScreenGui)
    CraftUI.luau          bench crafting menu
    BotClient.luau        bot attach/brain UI
tests/
  check-syntax.sh         lua5.1 syntax gate (Luau caveats noted)
docs/
  PORT-ARCHITECTURE.md    this file
```

## The extraction map (JS → Luau)

| Original (src/) | Port (src/) | Numbers kept |
|---|---|---|
| `data/blocks.js` B, BLOCK_DEF | `shared/Blocks.luau` | all 25 ids, colors, hardness (0.25–1.2 s), dropChance/altDropChance |
| `World.js` lcg/generate | `WorldGen/LCG.luau` + `YardBuilder.luau` | seed 42, 128×128, bands z 0–31/32–63/64–95/96–127, roads x=8/64/120, oval c(35,84) r(14,7), stations, densities, heights |
| `Game.js` mine/drops | `Systems/MiningService.luau` | progress = dt/hardness, drops, lucky find 3% day / 8% night, LUCKY_BLOCKS, LUCKY_LOOT |
| `data/recipes.js` | `shared/Recipes.luau` | MVP chain recipes verbatim |
| `maker/kinematics.js` | `shared/Config.luau` + `BrainVM.luau` | DRIVE_SPEED 3.0, TURN_RATE 180°/s, BOT_RADIUS 0.3, SONAR_RANGE 6.0 |
| `maker/VirtualRobot.js` | `Systems/BrainVM.luau` | axis-separated slide collision, heading wrap, [-π,π] |
| `maker/TileProgram.js` EXAMPLE_WALL_AVOIDER | `shared/TileProgram.luau` STARTER_WALL_AVOIDER | exact program tree |
| `maker/GameWorldAdapter.js` | `Systems/WorldModel.luau` | distanceAhead: 24-step ray, raw=(t−0.25)/range |
| `DayNight.js` | `Systems/DayNightService.luau` | CYCLE 360 s, isNight t<0.25‖t>0.78, start 0.35 |
| `ScrapBot.js` mesh + battery | `Systems/BotService.luau` | proportions, battery 1.3%/s drive, 0.4%/s idle, warn 15% |

## Coordinate mapping (yard units → studs)

- Yard is 128×128 cells. **CELL = 4 studs.** Yard cell (x, z) → Roblox studs
  `sx = x*4 − 256`, `sz = z*4 − 256` (cell center: +2). Map spans −256..256.
- Block level L (1..9) → studs Y = (L−1)*4 .. L*4. Ground slab top = Y 0.
- Bot sim runs in **yard units** (blocks, matching original kinematics); render
  maps `pos*4 − 256 + 2`. heading: 0 = +Z, forward = (sin θ, 0, cos θ) — same
  convention as original; Roblox `CFrame.lookAt(pos, pos + fwd)` with model
  front on the −Z face (Roblox standard).

## Phase 1 scope — the MVP loop (what "breathes" means)

1. Server generates the yard procedurally at boot, seeded 42, layout laws from
   the original `World.js` (band densities, cluster shapes, roads, oval,
   stations, sheds, junk cars, crystals, plaques).
2. **Mine**: raycast target + hold E → progress dt/hardness → drops (real
   tables) → inventory (server-authoritative) → client UI stub shows it.
3. **Craft**: at a Workbench (ProximityPrompt) → menu of real recipes.
   MVP chain: wrench → pliers → ultrasonic_module → tin_brain.
4. **Bot**: Gate Edition chassis spawns by the bench (canon: cold-start fast
   lane). Attach crafted module + brain (prompt on bot) → load
   STARTER_WALL_AVOIDER → bot drives 3 blocks/s, sonar raycasts 6 blocks,
   turns to avoid walls, battery drains at real rates.
5. Day/night: 360 s cycle drives Lighting.ClockTime; night = lucky-find boost.

### Phase 1 simplifications (honest stubs — documented, not hidden)

- **Ground** is one slab + 4 band tint strips + road strips instead of 16,384
  per-cell ground voxels. Ground blocks (dirt/gravel/concrete) have no drops in
  the original, so **zero mechanical loss**; band identity reads through tints,
  clutter density, and landmarks. Full per-cell ground is a later-graphics pass.
- **Crafting** covers the MVP chain + a few real extras, not all ~60 recipes.
- **Tile editor GUI** is Phase 2+; Phase 1 ships pre-built starter brains as
  data (the Wall Avoider from the original examples).
- **Save system, bots 2+, personalities, ledger** — later phases.

## Roblox-specific adaptations (not in the original, flagged)

- ProximityPrompt at bench/bot instead of E-on-crosshair station UI (Roblox
  idiom; mining keeps hold-E on crosshair).
- MINE_REACH_STUDS = 10 (2.5 cells) — original is a first-person crosshair game
  with perk-based reach; 10 studs reads right in third person.
- StreamedAsync default; all yard parts Anchored + CanTouch false, CanQuery
  true only for mineables (perf).
