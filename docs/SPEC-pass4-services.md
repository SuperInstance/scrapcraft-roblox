# SPEC — Pass 4 (parallel): gameplay services + client UI + dev tooling

You are building the MVP gameplay loop for the Scrapcraft Roblox port.
Read first (source of truth / already-done modules):

- Architecture: `docs/PORT-ARCHITECTURE.md`
- Config: `src/shared/Config.luau`, Blocks: `src/shared/Blocks.luau`,
  Items: `src/shared/Items.luau`, Recipes: `src/shared/Recipes.luau`
- ORIGINAL GAME mining/drops code (real behavior to port):
  `/home/eileen/projects/Scrapcraft/src/Game.js` lines ~1140–1240
  (`_updateMine`, drops, lucky find) and `/home/eileen/projects/Scrapcraft/src/DayNight.js`
- Contract you code against (being built in parallel by another pass —
  follow the API EXACTLY, do not read/modify those files):
  `WorldModel.init(level1: table)`, `WorldModel.removeBlock(x, z, level): Part?`
  (destroys the part, returns it), `WorldModel.isSolidAt(x, z)`.
  `YardBuilder.generate(parent, seed)` returns `{ landmarks = {workbench = {x=,z=}, forge=..., smelter=...}, level1 = ..., partCount = n }`.

## Deliverable 1 — `src/server/Systems/DayNightService.luau`

- Server heartbeat (RunService.Heartbeat accumulate dt).
- `t` cycles 0→1 over `Config.DAY_CYCLE_SECONDS` (360), starts
  `Config.DAY_START_T` (0.35). Map to Roblox: `Lighting.ClockTime = t * 24`.
- `DayNightService.isNight(): boolean` — DayNight.js: `t < 0.25 or t > 0.78`
  (use Config values).
- Set `Lighting.ClockTime` server-side; add Atmosphere/ambient hints:
  on night, `Lighting.Ambient` dark navy (40,45,80), day (150,140,120) —
  smooth lerp, cheap (update once per Heartbeat is fine).
- Expose `DayNightService.getT()`.

## Deliverable 2 — `src/server/Systems/InventoryService.luau`

- `InventoryService.get(player) -> { [itemId: string] = count }` (server-side
  table; create on PlayerAdded).
- `InventoryService.add(player, itemId, qty)` → returns list of
  {itemId, delta} for client sync; clamps at Items.DEF stack? No — Phase 1
  simple: single counter per item, no stacks.
- `InventoryService.has(player, itemId, qty)`, `.count(player, itemId)`,
  `.consume(player, itemId, qty): boolean` (all-or-nothing).
- Broadcasts inventory to that player only via RemoteEvent `ScrapcraftInv`
  (see Net below) with `{ type = "inv", items = {...} }`.

## Deliverable 3 — `src/server/Systems/MiningService.luau`

Port of Game.js mining. Server-authoritative:

- RemoteEvent `ScrapcraftMine`: client sends `{ part = Instance }` when
  holding E on a mineable target (client does raycast + progress display;
  server VALIDATES, see below).
- On request `MineService.beginMine(player, part)`: validate part has
  CollectionService tag "Mineable" + attribute BlockId, and character
  distance from part ≤ `Config.MINE_REACH_STUDS + 6` (latency slack).
- The hold loop is CLIENT-side for responsiveness; the SERVER decides the
  outcome on `finishMine(player, part)`: server tracks when that player
  began mining that part (`startedAt` per player); require elapsed ≥
  `Blocks.DEF[id].hardness * 0.9` (10% tolerance). If part already mined →
  reject silently. On success:
  1. `WorldModel.removeBlock(x, z, level)` (destroys part).
  2. Roll drops — Game.js L1197–1201 exactly:
     primary `drop` at `dropChance` (qty = def.dropQty or 1), then `altDrop`
     at `altDropChance` (qty 1). `InventoryService.add` each.
  3. Lucky find — Game.js L1211–1216: if `Blocks.LUCKY_BLOCKS[id]` and
     `rng < (isNight and 0.08 or 0.03)` → add 1 random from
     `Blocks.LUCKY_LOOT`. Server RNG: use `Random.new()` instance (member).
  4. Fire `ScrapcraftMine` back to player: `{ type="mined", id=blockId,
     drops={{itemId,qty},...}, lucky=itemId? }` for UI feedback.
- Debounce: 1 active mine per player; cancel if part changes.

## Deliverable 4 — `src/server/Systems/CraftingService.luau`

- ProximityPrompt-based: for every Part tagged "Station" (attribute
  `Station` = "workbench"|"forge"|"smelter"), add a ProximityPrompt
  (ActionText = "Craft", ObjectText = station name, RequiresLineOfSight
  false, MaxActivationDistance 10). One shared handler:
  prompt.Triggered(player) → open craft menu via RemoteEvent
  `ScrapcraftCraft` `{ type="open", station=... , recipes=Recipes.forStation(station) }`
  (send recipe list without tooling).
- RemoteEvent `ScrapcraftCraft` from client `{ type="craft", recipeId }`:
  validate recipe exists + station match is irrelevant Phase 1 (menu only
  offers valid ones) BUT check `recipe.tool` → `InventoryService.has`;
  check + consume ingredients; `InventoryService.add(output, qty)`;
  reply `{ type="crafted", output=..., qty=..., quip=recipe.quip }`.

## Deliverable 5 — Net module `src/shared/Net.luau`

```lua
local Net = {}
Net.REMOTES = { Mine = "ScrapcraftMine", Inv = "ScrapcraftInv",
                Craft = "ScrapcraftCraft", Bot = "ScrapcraftBot" }
function Net.remote(name): RemoteEvent  -- get-or-create in ReplicatedStorage
```
(All passes share this — create it exactly as specced.)

## Deliverable 6 — client files

`src/client/init.client.luau`: requires the three client modules below.
`src/client/MiningClient.luau`:
- Every frame (RenderStepped): camera raycast (256 studs, RaycastParams
  FilterDescendantsInstances = {workspace.Scrapcraft} Include only — build
  RaycastParams with FilterType Include). Hit part tagged Mineable +
  Highlight (singleton Highlight instance, parented to hit) +
  within `Config.MINE_REACH_STUDS` → show "Hold E" billboard (single
  ScreenGui label bottom-center instead — simpler: text label).
- While E held + same target part: progress += dt / hardness (from
  Blocks.DEF[part.BlockId].hardness — attribute read, NOT server). Show
  progress bar (simple Frame with size lerp). On complete → fire
  `ScrapcraftMine { type="finish", part=part }` then reset. Also fire
  `{ type="begin", part=part }` at press (server uses for timing check).
- Handle `ScrapcraftMine` replies: `mined` → floating drop toast list.

`src/client/InventoryUI.luau`:
- ScreenGui "ScrapcraftUI": left column frame, title "Scrap Pouch", item
  rows (icon+name xN) rebuilt on `ScrapcraftInv` messages. Minimal styling:
  dark background, white text. Also a "hint line" bottom-right cycling
  strings: "Mine scrap piles for iron", "Craft a wrench at the bench
  (E)", "Attach module + Tin Brain to your bot", "Watch it roam".

`src/client/CraftUI.luau`:
- On `ScrapcraftCraft {type="open"}`: centered frame listing recipes
  (name, ingredients "2x Iron Scrap, 1x Wood Plank", craftable state from
  last known inventory snapshot — client caches inventory from Inv events).
  Click row → fire craft request → on `crafted` close (or stay open,
  update). ESC/close button.

`src/client/BotClient.luau`:
- Phase 1 STUB (bot logic is another pass): listens on `ScrapcraftBot`
  for `{type="status", ...}` messages → small top-center toast text
  ("Bot: module attached", "Brain loaded: Wall Avoider").

## Deliverable 7 — server bootstrap update `src/server/init.server.luau`

Wire order: YardBuilder.generate → WorldModel.init → DayNightService.init →
InventoryService.init (PlayerAdded) → MiningService.init →
CraftingService.init → print `[scrapcraft] MVP services up` + the yard
summary line. (YardBuilder/WorldModel files exist from the parallel pass —
require by the exact paths `script.WorldGen.YardBuilder`,
`script.Systems.WorldModel`.)

## Deliverable 8 — tooling

`tests/check-syntax.sh`: bash, `set -e`, runs `/usr/bin/lua5.1 -p` on every
`*.luau` under src/ (note: lua5.1 is a SYNTAX-ONLY gate; if a file uses
intentional Luau-only syntax, list it with an exception comment in the
script). Also `rojo sourcemap --check default.project.json 2>/dev/null ||
true` no — skip rojo in the script; instead validate
`python3 -c "import json;json.load(open('default.project.json'))"`.

`README.md` (repo root): the developer loop — see Deliverable 9.

## Deliverable 9 — README.md dev loop (THE real commands)

Write a clean README:
1. One-time: install Rojo plugin in Roblox Studio (Studio → Plugins → manage
   plugin via .rbxm from rojo.space / or `rojo plugin install` if available).
   Note Studio must be Windows-side; rojo runs in WSL.
2. Serve: `cd /home/eileen/projects/scrapcraft-roblox && rojo serve` (WSL;
   default port 34872; WSL2 localhost forwarding makes it reachable from
   Windows Studio automatically).
3. Studio: open new Baseplate place → Rojo plugin → Connect. Tree syncs.
   Press Play. Yard generates server-side on run.
4. Fallback (Argon, Windows side): `~/.argon/bin/argon.exe watch
   //wsl.localhost/<distro>/home/eileen/projects/scrapcraft-roblox` — note
   Argon 1.x uses its own plugin; verify plugin installed. Mark as
   ALTERNATIVE, Rojo is primary.
5. Syntax gate before commit: `./tests/check-syntax.sh`.
6. "What's real vs stubbed" table (mine/craft/attach/brain = real;
   editor GUI, saves, bots 2+ = stubbed — pull from PORT-ARCHITECTURE.md).
   Include the exact MVP loop walkthrough a playtester follows.

## Style

`--!strict` everywhere (relax to `--!nonstrict` only if a client UI file
fights the checker — note it). No shell/os/io in Luau. No waits in hot
paths. Comment citations to original Game.js line numbers where behavior
was ported. When done print `PASS4-DONE` + summary.
