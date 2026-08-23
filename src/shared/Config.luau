--!strict
-- Config.luau — global constants for the Scrapcraft Roblox port.
-- Every number traced to the original source (provenance noted).

local Config = {}

-- ── World ──────────────────────────────────────────────────────────────────
-- World.js: constructor(width=128, depth=128, height=10); seed 42
Config.MAP_SIZE = 128          -- World.js default
Config.MAP_HEIGHT = 10         -- World.js default (levels y 0..9)
Config.SEED = 42               -- World.js generate(seed = 42)
Config.CELL = 4                -- studs per yard cell (Roblox adaptation, see PORT-ARCHITECTURE.md)
Config.MAP_ORIGIN = -Config.MAP_SIZE * Config.CELL / 2  -- -256; yard (0,0) → studs origin

-- Bands — World.js BANDS / yard-bible.md "Canon Inventory"
Config.BANDS = {
	{ z0 = 0,  z1 = 31,  name = "The Yard Gate" },
	{ z0 = 32, z1 = 63,  name = "Industrial Corridor" },
	{ z0 = 64, z1 = 95,  name = "Circuit City" },
	{ z0 = 96, z1 = 127, name = "The Deep Yard" },
}

-- Roads — World.js: for rx of [8, 64, 120], 3-wide concrete
Config.ROADS_X = { 8, 64, 120 }

-- The Proving Oval — World.js band2: center (35, 84), radii 14 x 7
Config.OVAL = { cx = 35, cz = 84, rx = 14, rz = 7 }

-- ── Day/night ──────────────────────────────────────────────────────────────
-- DayNight.js: CYCLE = 360; isNight t < 0.25 or t > 0.78; start 0.35 (morning)
Config.DAY_CYCLE_SECONDS = 360
Config.DAY_START_T = 0.35
Config.NIGHT_T_MAX = 0.25      -- isNight: t < 0.25 or t > 0.78
Config.NIGHT_T_MIN = 0.78

-- ── Mining ─────────────────────────────────────────────────────────────────
-- Game.js _updateMine: progress += dt / BLOCK_DEF[id].hardness  (hold to mine)
-- Lucky find: Game.js L1213: night ? 0.08 : 0.03
Config.MINE_REACH_STUDS = 10   -- Roblox adaptation (PORT-ARCHITECTURE.md)
Config.LUCKY_CHANCE_DAY = 0.03
Config.LUCKY_CHANCE_NIGHT = 0.08

-- ── Bot kinematics ─────────────────────────────────────────────────────────
-- maker/kinematics.js — exact
Config.DRIVE_SPEED = 3.0       -- blocks / second at power 1.0
Config.TURN_RATE = 180         -- degrees / second at power 1.0
Config.BOT_RADIUS = 0.3        -- blocks, wall collision sampling
Config.SONAR_RANGE = 6.0       -- blocks; distance_ahead normalizes vs this

-- ScrapBot.js battery: idle 0.4 %/s, driving 1.3 %/s; warn at 15%
Config.BATT_DRAIN_IDLE = 0.4
Config.BATT_DRAIN_DRIVE = 1.3
Config.BATT_WARN_PCT = 15

-- ScrapBot.js: BOT_SPEED 4.5 (follow mode), FOLLOW_DIST 3 — Phase 1 follow stub
Config.BOT_FOLLOW_SPEED = 4.5
Config.BOT_FOLLOW_DIST = 3.0

-- ── Helpers ────────────────────────────────────────────────────────────────

function Config.bandOf(z: number): number
	-- World.js _bandOf
	if z < 32 then return 0 end
	if z < 64 then return 1 end
	if z < 96 then return 2 end
	return 3
end

function Config.bandName(z: number): string
	return Config.BANDS[Config.bandOf(z) + 1].name
end

-- Yard cell (x, z) → stud center position on the ground plane.
function Config.cellToStud(x: number, z: number): (number, number)
	local s = Config.MAP_ORIGIN + x * Config.CELL + Config.CELL / 2
	local t = Config.MAP_ORIGIN + z * Config.CELL + Config.CELL / 2
	return s, t
end

-- Block level (1..) → stud Y of the block's center.
function Config.levelToStudY(level: number): number
	return (level - 1) * Config.CELL + Config.CELL / 2
end

return Config
