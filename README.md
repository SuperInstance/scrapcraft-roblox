# Scrapcraft — Roblox Port

The Scrapcraft yard (three.js voxel original at `/home/eileen/projects/Scrapcraft`)
ported to Roblox Studio via **Rojo**. Architecture, extraction provenance and
coordinate mapping live in [docs/PORT-ARCHITECTURE.md](docs/PORT-ARCHITECTURE.md) —
every tuning number in this repo is extracted from the original source, never guessed.

## The developer loop

**Stack split:** Roblox Studio runs Windows-side; `rojo` runs in WSL (Ubuntu).
WSL2 forwards `localhost` both ways, so Studio connects to WSL-served rojo with
zero extra setup. (Verified: Rojo 7.5.1 at `~/.cargo/bin/rojo`; `rojo serve`
listens on `localhost:34872`.)

### 1. One-time — install the Rojo plugin in Studio

Studio → Plugins → **Manage Plugins** → install the Rojo plugin (Rojo 7.x):

- Either download the latest `rojo-rbx.x.rbxm` from <https://rojo.space> (or the
  GitHub releases page linked there) and use *Install Plugin:…* / drag the
  `.rbxm` into Studio's Plugins folder, **or**
- from WSL: `rojo plugin install` (if your rojo build ships it) — it drops the
  `.rbxm` where Studio can find it; restart Studio after.

Remember: Studio must be the Windows-side app; rojo stays in WSL.

### 2. Serve the project (WSL)

```bash
cd /home/eileen/projects/scrapcraft-roblox && rojo serve
```

Default port **34872**. WSL2 localhost forwarding makes it reachable from
Windows Studio automatically — no IP gymnastics.

### 3. Connect in Studio

1. Open a **new Baseplate** place (any baseplate; the yard is generated at run
   time, not baked into the place file).
2. Rojo toolbar → **Connect** (leave host/port defaults).
3. The tree syncs: `ReplicatedStorage.Shared`, `ServerScriptService.Server`,
   `StarterPlayerScripts.Client`.
4. Press **Play**. The server generates the yard (seed 42) and you should see
   in the output:
   `[scrapcraft] MVP services up` and
   `[scrapcraft] yard generated: N parts, workbench @ x,z`.

### 4. Fallback (ALTERNATIVE): Argon live-sync

Rojo is the primary path. If you prefer Argon (Windows-side binary, its own
Studio plugin — verify the Argon plugin is installed in Studio first):

```powershell
~/.argon/bin/argon.exe watch //wsl.localhost/ubuntu/home/eileen/projects/scrapcraft-roblox
```

### 5. Syntax gate + headless smoke tests before commit

```bash
./tests/check-syntax.sh                     # luau-analyze (Roblox defs) + luac5.1 -p + JSON validation
/usr/bin/lua5.1 tests/smoke_pass2.lua      # worldgen determinism + WorldModel
/usr/bin/lua5.1 tests/smoke_mvp.lua        # the WHOLE MVP loop, headless
/usr/bin/lua5.1 tests/smoke_phase2.lua     # editor core, editor→VM run, gate queue, persistence
```

- **Primary gate: `luau-analyze`** (real Luau parser, at `~/.local/bin/luau-analyze`)
  with Roblox API definitions (`tests/globalTypes.d.luau`, from luau-lsp) —
  so Luau type annotations are checked natively. Syntax errors fail the gate.
- Secondary: `luac5.1 -p` (pure Lua 5.1 syntax) — files using Luau-only syntax
  (type annotations etc.) are expected to be unparseable by it; the count is
  reported honestly rather than skipped silently (currently 17 of 21).
- `tests/smoke_mvp.lua` stubs the Roblox API and drives the REAL server
  modules under plain lua5.1 (Luau annotations stripped at load time):
  mine → drops → inventory → craft (tool gates, all-or-nothing) → attach
  module + Tin Brain → starter brain runs → bot moves, avoids walls, drains
  battery at the real rates → clear → battery death. It also regression-tests
  the level≥2 mining destroy fix (stacked parts are destroyed; the level-1
  occupancy under them is untouched).
- Strict-mode type *notes* (heterogeneous table inference, `script.Parent`
  requires) are printed but non-blocking in Phase 1.

## What's real vs stubbed (Phase 1)

| System | Status |
|---|---|
| Mine (hold-E, hardness timing, drops, lucky finds, night bonus) | **real** — ported from `Game.js` `_updateMine`/`_completeMine`; level≥2 stacked blocks destroy correctly (regression-tested) |
| Craft (stations, tool gates, ingredients, quips) | **real** — MVP chain: wrench → pliers → ultrasonic module → tin brain (+ hammer, track strips) |
| Attach module/brain to bot | **real** — BotService (ProximityPrompt flow, Gate Edition chassis from `botEditions.js`) |
| Bot brain (Wall Avoider, sonar, battery) | **real** — BrainVM (`VirtualRobot.js`/`TileVM.js`/`primitives.js` port; battery 0.4/1.3 %/s × 1.25 gate mult) |
| Day/night (360 s cycle, lighting, lucky-find boost) | **real** — `DayNight.js` port |
| Ground rendering | simplified — 1 slab + band tints + roads (zero mechanical loss; see PORT-ARCHITECTURE) |
| Recipe book | subset — MVP chain + tier-1 extras (~60 recipes land Phase 2) |
| Tile editor GUI | **REAL (Phase 2)** — the Brain Workbench: visual tile editor at the bench (key **B**) — palette, drag/snap, click-to-wire, per-tile params, SAVE & RUN into the live BrainVM (data core proven by round-trip tests; GUI kimi-built, review-fixed) |
| Earl's gate ceremony | **REAL (Phase 2)** — queue with numbered hard hats, Earl's canon lines, the bell (3 rings), candy every 8s to the line, doors that swing open on your answer; returning regulars skip (clack + one line). Ceremony area is escapable by determined walkers (open yard) — containment is vibes-first v1 |
| Persistence | **REAL (Phase 2)** — `PlayerProfiles_v1` DataStore: inventory, gate state, last editor program; 180s session lease, 12s buffered flush, save-on-leave + BindToClose, pcall everywhere (Studio without API access → memory-only fallback, honest note below) |
| Bots 2+, personalities, ledger | **stubbed** — later phase |

The full mine→craft→attach→brain→move loop is verified headless by
`tests/smoke_mvp.lua`; Phase 2's editor data core, gate queue, and persistence
by `tests/smoke_phase2.lua` (51 checks — see “Syntax gate + headless smoke
tests” above) — the same service code Studio runs.

## Phase 2 — what shipped (2026-08-23, branch `phase2-build`)

Three checkpoints, each test-gated:

1. **The Brain Workbench (tile editor)** — open it at the workbench (**B**).
   Build a brain from tiles (Drive/Turn/Stop/Beep/LED + Wait/If-Else/Forever),
   wire them (cyan = next, purple = loop body, red = else), set a START tile,
   then **SAVE & RUN ▶** — it validates, keeps the module→brain economy
   (reprogramming a running brain is free), and your program runs on the yard
   bot through the same BrainVM. Your last brain persists in your profile.
   The editor edits a node graph that serializes to EXACTLY the program tree
   `BrainVM` executes (round-trip proven) — one format from tiles to motor
   pins, matching the web TileProgram schema.
2. **Earl's gate with queue** — first-timers spawn south of the closed doors,
   take a numbered hard hat, and get Earl's full greeting (canon-verbatim
   beats; answer "I can dig" or ask about the blue drum — both paths open the
   gate). The line gets scrap candy every 8s (→ Silly Hats at the bench),
   the front can ring the bell three times, idle players drift back one slot
   per 90s (the gate is patient). Returning regulars skip it all: the gate
   just clacks open with one gruff-warm line.
3. **Persistence v1** — profiles with a 180s session lease (60s refresh, so
   teleports never double a kid; a crashed server releases in ≤3m), dirty
   flush every 12s, save-on-leave, BindToClose. Failure to load = fresh
   start at the gate, never a brick. **Honest limits:** a stuck lease from a
   live server is overridden after 3 retries (playtest-friendly, not
   split-brain-proof); Studio without Studio API access runs memory-only.

## The MVP loop (playtester walkthrough)

1. **Spawn** at the yard gate (Earl's pylons, road at x=8). It's morning.
2. **Mine**: look at a Scrap Pile / Rusted Metal / crate-shaped block (it
   highlights when aimed at; "Hold E — Scrap Pile" appears in reach). Hold **E**
   until the bar fills. Drops land in the **Scrap Pouch** (left panel) — e.g.
   `+ Iron Scrap`. Occasionally a 🍀 **Lucky Find** pops (3% day / 8% night from
   junk piles, drums, cars).
3. **Craft a wrench**: walk to the **Workbench** (follow the hint line,
   bottom-right), press **E** on its *Craft* prompt. Pick **Wrench**
   (3x Iron Scrap, 1x Wood Plank — mine Rotted Wood for the plank). Craft
   **Pliers** next (2x Iron Scrap, 1x Copper Wire — power boxes and crates).
4. **Modules**: with Pliers in the pouch, craft the **Ultrasonic Module**
   (circuit board + copper wire — crates/power boxes drop them) and the
   **Tin Brain** (2x Circuit Board, 4x Copper Wire, 3x Iron Scrap).
5. **Bot**: find the Gate Edition chassis by the bench, attach the module +
   Tin Brain via its prompt, load the starter brain.
6. **Watch it roam** — sonar-driven wall avoidance at 3 blocks/s; battery
   drains at the real rates. `status` toasts appear top-center.
7. Meanwhile: night falls around the ¾ mark of the 6-minute cycle — ambient
   goes navy, lucky-find odds jump to 8%. Keep mining.

## Repo layout

See [docs/PORT-ARCHITECTURE.md](docs/PORT-ARCHITECTURE.md) for the full map
(`src/shared` data + constants, `src/server` worldgen + services (incl.
`Systems/BrainVM.luau` + `Systems/BotService.luau`), `src/client` UI,
`tests/` syntax gate + headless smoke suites).
