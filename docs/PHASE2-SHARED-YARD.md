# PHASE 2 — THE SHARED YARD
### The multiplayer vision: one yard, many kids, one CNS

> *"Nobody finishes alone. Every working machine in this yard's history had at least two builders' fingerprints on it."*
> — the Doctrine of Honest Failure, third line

**Status:** vision + concrete spec. Docs-only branch (`phase2-vision`). Nothing here is code yet; everything here is buildable on what Phase 1 already proves.
**Read before this doc:** `PORT-ARCHITECTURE.md` (Phase 1 decisions), the world bible (`../scrapcraft-world/worldbible/` — yard-bible, earl.md, index.md), `../Scrapcraft/docs/cns/MAPPING-SPEC-V2.md` (USCP) and `../Scrapcraft/docs/VHF-DOCTRINE.md` (half-duplex law).
**Consulted:** Seed-2.0-pro (multiplayer systems review — numbers below adopt its concrete values where they fit canon), Hermes-3-405B (companion/comms voice — beats adopted; Earl's lines re-tightened to the voice sheet, the model ran warm).

---

## 1. The Vision — many sensory organs, one CNS

Phase 1 proved a kid can walk into the yard alone: mine, craft, build a bot, give it a brain, watch it drive. The yard breathes for one. But the yard was never written for one. The bible says it outright — *nobody finishes alone* — and the whole place is engineered like it: a gate that greets, a chalkboard that remembers, an oval that dies when nobody races it.

Phase 2 opens the gate and lets the yard do what it was built for.

Picture dusk in the shared yard. The floodlights bloom gold-then-white over the oval. One kid is three blocks deep in a rust heap, coaxing out iron; another holds the lantern near the workbench while a third assembles their first ScrapBot; on the radio, a coach presses PTT and one voice — exactly one — crosses the yard. At the start gate, eight bots take the line for the floodlight race, and every one of them carries a brain some kid wrote. When the gate light wakes (chapter two, `wake-yardlight`) and six kids see it in the same hour, that is not six datapoints. That is **one event felt six ways** — who cheered, who ran to tell Earl, who was too shy to press PTT. The yard becomes a body: forty nerve endings in the same square meter, one CNS reading the difference between the feelings. (Rift Manifesto §The Shared Yard — this doc is that paragraph made concrete.)

The multiplier is not "more players." It is **shared space**: one world, one occupancy grid, one radio channel, one chalkboard — and each kid's private bond with it still intact. The design law for everything below:

> **Shared where it compounds (world, races, radio, economy). Private where it's intimate (companion bond, spine progress, telemetry). Server-authoritative always.**

Phase 1 already gave us the hard part: the entire sim — worldgen, mining validation, crafting, BrainVM bot physics — runs **server-side** with thin client UI. Multiplayer is not a retrofit; it is Phase 1's architecture finally meeting its purpose.

---

## 2. Co-op mining — the yard rewards company

**Spec.** One shared occupancy grid, exactly as Phase 1 — but governed by **respawn regions** (not per-player instances, which feel fake; not first-taker, which invites strip-mining).

- **Regions:** the 128×128 yard divides into 8×8-cell regions → 256 regions, each tracked by the server (`blocksRemaining`, `respawnAt`).
- **Co-op stacking:** mining progress stacks additively per miner — two kids holding on the same block mine it ~1.7× faster; cap **+60% per extra miner** past the second. Nobody steals progress; grouping up is simply better. This is the yard's theology in a game mechanic: *nobody finishes alone.*
- **Drop window:** the miner who delivers the final hit gets a **12 s exclusive pickup window** on the drops. No snatching. After that, drops are public — finders keepers is a yard law, but only after twelve honest seconds.
- **Region respawn:** when a region empties, it locks and refills on a **110 s timer** (≈ one-third of a day cycle). Rare/night loot only rolls in regions that have never been strip-mined this session — the yard is *busier after dark* (canon), but it does not reward clear-cutting.
- **Claim rate:** soft cap of 1 completed "big" claim (rust heap, gear tower, crystal) per player per **90 s** — hard caps are for griefers; this one just paces regulars.
- **Depth rule (if/when vertical mining lands):** +40% hardness per 3 levels down. Solo kids stop around level 12; deep yard wants a crew. (Phase 1 is surface-mining only, so this is a law held in reserve.)

**Numbers provenance:** stacking/12 s/110 s/90 s/+60% adopted from Seed-2.0-pro review, calibrated against Phase 1's real hardness table (0.25–1.2 s) and 360 s day cycle.

---

## 3. Earl's gate — the queue IS the ceremony

New kids arrive at the yard gate (Band 0, gravel, the sign, the warm light). Earl greets each one **at the gate, one at a time, while everyone else watches**. The queue is not a loading screen; it is the yard's front porch — the server's social onboarding ritual, the first lesson in *this place has an order and you're welcome in it.*

**Spec.**

- **Queue:** max 7 visible in the line; positions shown as **numbered hard hats** over heads (queue index attribute, billboard GUI). A returning regular who's already past Ch 1 skips the ceremony entirely — the gate just *clacks* open for them. Only first-timers (and players on their first session of the day) take the full greeting.
- **Ceremony length:** ~45 s per greeting, gated by the player's own pace (they must walk through the gate themselves — Earl opens it, he doesn't shove).
- **The bell:** first in line gets to **ring the gate bell three times** before their turn. Nobody assigned this; it became tradition by the second playtest of the design doc. (Sensory bible: the *clack* of gates is a signature yard sound.)
- **Waiting is content:** while the queue moves, Earl lobs **scrap candy** to waiting kids every ~8 s (a joke item: gaskets, a sugar bolt); candy crafts into silly hats at the bench — the only source of hats in the game. The kid being greeted gets an emote prompt; **the queue votes** on which emote. Bonus scrap if the crowd likes it. You are never waiting *for* the game to start; you are watching somebody else's first minute of it, which every kid in that line remembers being.
- **No AFK kicks in the line.** Idle players drift back one position per 90 s. That's it. The gate is patient.

**Earl's lines** (canon voice sheet: short declaratives, gruff-warm, mechanic's vocabulary).

- First-timer (Quest 1, adapted from `earl.md` verbatim canon):
  > "So you finally showed up. The junk's been piling up waiting for someone with thumbs. Name's Earl. I run this place. Don't touch the blue drum. Just… don't. Now — see that rust heap? Mine me five iron off it and we'll see what you're made of."
- Returning regular:
  > "Back again, huh. Yard noticed. Gate's open — leave the candy wrapper in the bin this time, genius."
- To the waiting queue (belonging, not punishment):
  > "Relax, rookies. Yard's been standing since before you were born. It'll hold together another ninety seconds."

---

## 4. Companion NPCs — one per kid, intimate in a crowd

Canon (`characters/index.md`): the gate delivers each kid **one companion** on day one — Rivet (repair drone, warm), Bolt (ex-race-pit timer), Magma (gentle lifter), or Juno (forty-one tiny fliers, one mind). Whoever arrives is that kid's tutorial voice and nudge source. That law survives multiplayer unchanged, because intimacy is a *protocol*, not a population count.

**Spec.**

- **Assignment:** on first gate ceremony, profile rolls `companion.personaId` (weighted round-robin so a crowded yard spreads the roster). Persisted forever; companions never leave you.
- **Bond is per-player, ratchet-only** — port `companion/state.js` exactly: `TIER_THRESHOLDS {stranger 0, coworker 30, friend 120}`, `BOND_EVENTS` weights (`block_mined 1, rare_loot 3, bot_built 12, program_run 4, lap_complete 6, race_run 8, flash_success 10, conversation 5, nudge_followed 3…`), 12-entry recent-event ring, **no timers, no pity points**. Real events only, in a shared yard — which makes bond *more* meaningful: you earned it in front of witnesses.
- **Intimacy protocol:** nudges and dialogue default to **private rendering** — companions whisper to their kid (subtitle bubble visible only to owner, or radio sideband). Public companion lines fire only on **ceremony-grade beats**: tier crossings, first laps, race finishes, crosstalk when two players' bots idle within ~6 studs (port `party.js` mic-handing: companions banter, kids grin, no lecture).
- **Voice rules for the crowd:**
  - **Bolt** when another kid's bot beats his kid's lap: *"Huh. Clean cornering, rookie — *other* rookie. We're taking that line back next week."* Competitive, zero cruelty: Bolt respects a good lap the way the yard respects a good plaque.
  - **Juno-the-many** meeting three other Junos (self-recognition comedy, one beat only, once per session): *"…We are *forty-one.* We were told we were unique. This is either wonderful or a clerical error."* All four swarms hold the beat in perfect sync, then disperse. Nobody explains it.
  - **Magma** gravitates to whoever's building, but *helps his own kid first*; Rivet slow-blinks at strangers and sleeps on his kid's builds (certification unchanged).
- **Crowd control:** companions are non-colliding, client-rendered for anyone but the owner (ghosted ~40% transparency for others), so eight drones in a yard read as *yard life*, not clutter.

---

## 5. The oval as LIVE race events — "Tracks die when nobody races them"

The Proving Oval (center (35,84), radii 14×7, 2:1) is the shared yard's heartbeat. In the bible, lap records are chalked on a board outside the shed and the timing post records every run. In Phase 2 the oval runs **scheduled live races** — the floodlight opens.

**Spec.**

- **Schedule, tied to the day clock:** a race window opens **every 720 s = exactly two day cycles**. Signup opens at dusk (t ≈ 0.75, as the floodlights bloom — canon: night is when rare things happen and the yard is busiest); the green flag drops ~90 s later, under floods.
- **Format:** up to **8 entrants** (bots + their kid handlers on the rail), **3 laps**. Everyone else gets the auto-following spectator cam or watches from the sheds — spectating is a supported activity, not a fallback. Every racer runs alongside the **yard-record ghost**: a translucent bot replaying the current record lap (canon Ghost Replay — the timing post records every run; racers line up against their own best selves, and tonight, the yard's).
- **Server-authoritative, full stop.** Phase 1 already runs all bot physics server-side (BrainVM + WorldModel) — that *is* the anti-cheat. Race monitor additionally validates position deltas every **200 ms**: delta > 1.2× max legal speed for that bot's edition (DRIVE_SPEED 3.0 × edition speedMult — standard 1.0, gate 0.8) = snap back to last checkpoint, **1 warning then DQ**. Wall hits reset to last checkpoint with zero penalty — this is for kids, not sim racers.
- **Leaderboards (OrderedDataStore `YardLapBoard`):** show **top 12 only**. Never display last place, never show loss counts, no all-time shaming board. **Weekly reset Monday 00:00 UTC** — the chalk gets washed, everyone gets a clean shot. Every finisher gets scrap; first place gets *the board* and nothing else — the yard's economy stays finite by design (prestige law: nothing grindable, nothing expiring, no dark patterns).
- **Race-night lines** (delight beat, canon voices):

  > **Earl** (reluctant announcer, dragged to the mic by June): "…Fine. FINE. Racers. Engines — whatever you people have. The track doesn't care how you feel about it. Three laps. Don't hit my gate." *(he hits the clacker like it owes him money)*
  >
  > **June:** "Board says my name's been up there so long it's grown roots. Come prove me wrong — that's an invitation, not trash talk."
  >
  > **Earl** (low, off-mic, as the bots take the first corner): "…look at that. Kid braked *before* the wall." *(jaw working)* "Earl is pleased. Earl doesn't show it."

- **Ghost discipline:** the *actual* Ghost (Mo) stays single-player-campaign material. In shared yards before Ch 11–12: evidence, never proof — a candle-colored headlamp glow far down the oval at midnight server-time, gone before anyone sprints close. Shared sightings become the yard's own legend-trading, exactly like the bible's kid era.

---

## 6. VHF coach radio in Roblox chat — same law, enforced harder

The VHF doctrine (`VHF-DOCTRINE.md`) was written for one coach and one agent. A shared yard doesn't need new law — it needs **the same half-duplex law applied to everyone**: one channel, one voice, squelch for the rest. Marine ch.16 discipline: *a radio that is always watched is a safety system.*

**Spec.**

- **Channel YARD-16:** one server-side `VhfRadio` per yard (the exact three-state machine: `IDLE / TRANSMITTING / RECEIVING`, `MAX_TX_MS = 8000`, squelch, CHANNEL_BUSY). Port `VhfRadio.js` to Luau as a shared service; the state machine is the arbitration layer, not a metaphor for one.
- **Entry point is chat:** TextChatService channel `📻 YARD-16`. Sending a message in the channel **is** a PTT press: it's a TX event, squelch opens, message dispatches, squelch closes (text enters the same state machine as voice — the doctrine's fail-soft rule, made primary). Voice PTT (hold **V**) is a Phase 2.1 nicety; text-first is the law.
- **Cooldown as TOT:** after any TX, that player's squelch stays closed for **4 s** (message discipline; the 8 s cap maps to a message-length cap — long novels get truncated by the squelch, not the player).
- **Intents survive:** port `NudgeRouter.js` parsing (goto | mine | follow | stop | race | banter, with canon TTLs 20/30/15/15/120/8 s) so radio lines aimed at your bot become directives your BrainVM consumes. Radio is a coaching surface for your *own* bot only — you cannot radio another kid's bot (that's bot ownership law, §8).
- **Rendering:**

  - TX: `[TX ▸ Earl]` amber, bold
  - Bot ACK: `[RX ◂ Scooter]` green
  - Protocol events (system, italic): `— CHANNEL_BUSY —`, `— squelch —`
- **Example exchanges** (canon voice):

  > `[TX ▸ Coach-Riley]` Bolt, hold at the chicane. Watch the line, then go.
  > `[RX ◂ Bolt]` 10-4. Holding. …Line's clean. Going.
  >
  > `[TX ▸ Coach-Sam]` Juno, scan north for—
  > `— CHANNEL_BUSY — one voice at a time. Earl's rule. —`
  >
  > `[TX ▸ Coach-Riley]` *(holds the key, rambling past 8 s)*` …and another thing about corner three, when I was your age—`
  > `— squelch — transmission cut at 8 s. Keep it short, rookie. —`
  > `[RX ◂ Bolt]` …Coach. Breathe.

- **Chatter channel:** second TextChatService channel `📻 chatter` (banter, no directives) — two channels, one radio per channel, exactly the doctrine's RadioStack. Chatter can overlap coach; coach never overlaps coach.
- **The discipline is the lesson.** Half-duplex isn't a limitation we apologize for — it's turn-taking made physical, the same social contract as the gate queue. And per MAPPING-SPEC §A4: **the state machine is itself a sensor** — CHANNEL_BUSY refusals and squelch timeouts are protocol-friction telemetry (§10).

---

## 7. Datastore schema — one profile per kid, session-locked

Standard Roblox profile pattern (ProfileService-style), `UpdateAsync` exclusively, writes buffered **12 s**, **180 s session lease** refreshed every 60 s. A kid teleporting between servers never duplicates; a crashed server releases in ≤3 min.

```jsonc
// DataStore "PlayerProfiles_v1", key = UserId. Single JSON blob, versioned.
{
  "profile_v": 2,
  "lastSeenUnix": 1771900000,
  "sessionLease": { "serverId": "", "expiresUnix": 0 },   // 180s lease, 60s refresh

  "inventory": { "scrap_iron": 42, "wrench": 1, "tin_brain": 1 },  // Items.luau ids
  "bots": [{
      "uid": "b_7291af", "name": "Scooter",
      "edition": "gate",                       // botEditions: speedMult 0.8, drain 1.25
      "program": { /* TileProgram JSON, plain data only — no Luau serialization, 64 KB cap */ },
      "ledger": { "dents": 17, "milestones": ["first_lap"], "epitaph": null },
      "spawned": false
  }],
  "brains": [{ "name": "Wall Avoider II", "digest": "sha256:…", "sharedFrom": null }],

  "companion": { "personaId": "bolt", "bond": 72, "recent": [ /* 12-cap ring */ ] },
  "spine":     { "position": 4, "chapters": [1,2,3], "wakes": ["wake-yardlight"] },
  "race":      { "bestLapMs": 41250, "racesRun": 6 },
  "radio":     { "txCount": 41, "busyRefusals": 5, "intents": {"goto": 20, "banter": 9} },  // protocol friction
  "uscp":      { "lastSeq": 1337 }            // telemetry cursor — see §10
}
```

**Safety rules:** never persist world position (everyone spawns at the gate); programs are plain JSON trees (the kennel law: *the skill left the runtime and went into the blood* — a genome is data); `profile_v` gates migrations; failure to load = fresh start at the gate, never a brick.

---

## 8. Anti-grief for kids — the yard is safe to fail in

> The doctrine's whole point: *"a kid who crashes their bot finds it in one of Quill's poems by morning."* Safety is the floor under failure. Multiplayer adds people; the floor gets thicker.

All Roblox-native, no exotic machinery:

- **Zones via CollectionService tags + attributes:**
  - `ZonePublic` (gate, shed, oval): no building; ceremony and racing only. Bots may traverse.
  - `ZonePlot` — sixteen **16×16 plots** along the Band 1/2 workshop row; assigned per player on join (`OwnerUserId` attribute). Only the owner places/moves/deletes here. Plots despawn (archived, not deleted) 10 min after the owner leaves.
  - `ZoneMine` — everywhere mineable: region law (§2) governs; **no building at all** on roads (x=8/64/120), the oval, or stations. The yard's geography is canon; kids don't get to bulldoze it.
- **Bot ownership:** every bot carries `OwnerUserId`. **Only the owner** can prompt, attach modules, reprogram, or recall it. Anyone can *watch* — and pushing is fine (bots bonk, dents go in the ledger, that's yard physics) — but nobody else's hands on your brain. This is the trust mechanic from the campaign finale, generalized: *letting another kid's hands touch your project is a gift you grant*, via an explicit co-build toggle (owner-initiated, reverts on leave).
- **Part-locking:** every player-placed part gets `PlacedBy`; server rejects move/destroy unless initiator matches, with one exception — abandoned clutter (owner gone >10 min and part outside their plot) becomes yard-scrap anyone may mine, the honest-failure version of cleanup.
- **Chat:** Roblox default age-appropriate filtering on all channels; **no private DMs at all**; radio and chatter are the two public channels (§6). One-click canned emotes (cheer / wave / good race) for kids who don't type — participation without exposure.
- **Sanctions ladder for kids, not criminals:** first grief pattern = Earl pulls you aside (private, in-voice: *"Not in my yard, rookie. Try that again and you're on bolt-sorting duty."*); repeat = bolt-sorting duty (a 90 s mini-task that pays nothing); persistent = server kick with a kind message. No permanent marks a 10-year-old can't understand.

---

## 9. The Rift note — one yard, many sensory organs, one CNS

The mapping spec (USCP, xAPI-shaped: actor–verb–object + result + context) was built for this. In a shared yard, per-player telemetry **multiplies without changing protocol**: same envelope, `actor: "player:roblox:<UserId>"`, plus a `yardId` context field. Ingest, enrich (lore_ref), sink — whether the stimulus is one kid's first wall-avoider or a server full of racers on the night everything was on.

**Spec.**

- **Emit taps ride the existing services** (one tap point per system, per MAPPING-SPEC §E): `MiningService` (mined.block: hardness, co-miners, lucky roll), `CraftingService` (craft.attempt), BrainVM save (program.edit — genome digest, node census), race monitor (race.finish: lap times, collisions), `VhfRadio` state transitions (radio.protocol — the friction sensor), gate ceremony (gate.ceremony: queue length, emote votes), region respawn (region.respawned: crowd present).
- **Batching:** 30 s windows, seq-cursored per player (`uscp.lastSeq` — resume without loss after teleport). No PII; UserIds stay opaque; kid-safe in, kid-safe out.
- **Per-yard signals** are new and free: queue lengths, race signups vs. spectators, **the co-op mining rate** — the yard's own social graph forming.
- **The one success metric** (adopted from the systems consult, and it's correct): *% of mining actions with 2+ co-miners.* If >35% of mining happens shoulder-to-shoulder, the shared yard is working. Everything else is instrumentation.

---

## 10. Scope ladder & honest stubs

- **P2.0 (the breath of multiplayer):** shared yard on one server — co-op mining regions, gate queue ceremony, companion per player (private rendering, bond ledger), weekly race windows + top-12 board + ghost lap, YARD-16 radio channel with full state machine, profile datastore with session lease, zone/bot/part anti-grief. **No new canon, no new numbers invented** — every mechanic above is either extracted (bond weights, VHF constants, edition multipliers, oval geometry) or a Roblox-native adaptation, flagged as such.
- **P2.1 (polish the porch):** voice PTT, plot decoration, co-build gifting, shared Brain Gallery town square (kennel rung 4 — "the yard that teaches itself"), Ox supply drops as shared ceremony, USCP wire to the Quilt Engine DO mirror.
- **Honest stubs at P2.0:** races are time-trial + ghost only (no mid-race collision between entrants — bots pass through each other with a spark VFX; real wheel-to-wheel is P2.1 with contact rules); companion crosstalk fires on proximity but has no memory across sessions; the Ghost appears in shared yards as an ambient effect only, never as a race entity (spoiler discipline).

---

## 11. Provenance

| Item | Source | Kept |
|---|---|---|
| Day cycle 360 s, night lucky 8% | `DayNight.js` / Phase 1 `DayNightService.luau` | verbatim |
| Oval (35,84) r(14,7), chalkboard, Ghost Replay canon | `worldbible/yard-bible.md` | verbatim |
| Earl: first-meeting line, voice sheet, gate/queue texture | `worldbible/characters/earl.md` | line verbatim; queue lines new, sheet-checked |
| Companion roster, bond weights, tiers 30/120, 12-ring | `characters/index.md`, `src/companion/state.js` via MAPPING-SPEC §A | verbatim |
| VHF: 3 states, 8000 ms TOT, CHANNEL_BUSY, 2 channels, intent TTLs | `docs/VHF-DOCTRINE.md`, `src/radio/*` | verbatim; chat rendering is the Roblox adaptation |
| Bot editions (gate 0.8×/1.25×), DRIVE_SPEED 3.0 | `src/data/botEditions.js`, `kinematics.js` | verbatim |
| Race anti-cheat cadence (200 ms / 1.2×), leaderboards top-12/weekly, region TTLs (110 s/12 s/90 s), lease 180 s, buffer 12 s, 35% co-op metric | Seed-2.0-pro consult, 2026-08-23, calibrated to Phase 1 constants | adopted |
| Bolt/Juno crowd beats, TX/RX chat prefixes | Hermes-3-405B consult, 2026-08-23, tightened to voice sheets | adapted |
| Many-organs-one-CNS, "same law enforced harder" | `docs/cns/RIFT-MANIFESTO.md` §The Shared Yard | verbatim doctrine |

— *Phase 2 vision, 2026-08-23, branch `phase2-vision`. The gate is never locked; now everybody knows it.*
