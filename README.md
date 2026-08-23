# Scrapcraft — Roblox Port

The Scrapcraft yard (three.js voxel original at `/home/eileen/projects/Scrapcraft`)
ported to Roblox Studio via **Rojo**. Architecture, extraction provenance and
coordinate mapping live in [docs/PORT-ARCHITECTURE.md](docs/PORT-ARCHITECTURE.md) —
every tuning number in this repo is extracted from the original source, never guessed.

## The developer loop

**Stack split:** Roblox Studio runs Windows-side; `rojo` runs in WSL (Ubuntu).
WSL2 forwards `localhost` both ways, so Studio connects to WSL-served rojo with
zero extra setup.

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

### 5. Syntax gate before commit

```bash
./tests/check-syntax.sh
```

- **Primary gate: `luau-analyze`** (real Luau parser, at `~/.local/bin/luau-analyze`)
  with Roblox API definitions (`tests/globalTypes.d.luau`, from luau-lsp) —
  so Luau type annotations are checked natively. Syntax errors fail the gate.
- Secondary: `luac5.1 -p` (pure Lua 5.1 syntax) — files using Luau-only syntax
  (annotations etc.) are expected to be unparseable by it; the count is reported
  honestly rather than skipped silently.
- Strict-mode type *notes* (heterogeneous table inference, `script.Parent`
  requires) are printed but non-blocking in Phase 1.
- Also validates `default.project.json` with python3.

## What's real vs stubbed (Phase 1)

| System | Status |
|---|---|
| Mine (hold-E, hardness timing, drops, lucky finds, night bonus) | **real** — ported from `Game.js` `_updateMine`/`_completeMine` |
| Craft (stations, tool gates, ingredients, quips) | **real** — MVP chain: wrench → pliers → ultrasonic module → tin brain (+ hammer, track strips) |
| Attach module/brain to bot | **real** — BotService pass (ProximityPrompt flow, starter brains) |
| Bot brain (Wall Avoider, sonar, battery) | **real** — BrainVM pass (STARTER_WALL_AVOIDER port) |
| Day/night (360 s cycle, lighting, lucky-find boost) | **real** — `DayNight.js` port |
| Ground rendering | simplified — 1 slab + band tints + roads (zero mechanical loss; see PORT-ARCHITECTURE) |
| Recipe book | subset — MVP chain + tier-1 extras (~60 recipes land Phase 2) |
| Tile editor GUI | **stubbed** — Phase 2+; Phase 1 ships pre-built starter brains as data |
| Save system / persistence | **stubbed** — later phase |
| Bots 2+, personalities, ledger | **stubbed** — later phase |

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
(`src/shared` data + constants, `src/server` worldgen + services, `src/client`
UI, `tests/check-syntax.sh` gate).
