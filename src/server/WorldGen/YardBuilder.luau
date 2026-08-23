--!strict
-- YardBuilder.luau — the whole Scrapcraft yard, deterministically from seed.
-- Port of /home/eileen/projects/Scrapcraft/src/World.js generate() + band
-- generators (_band0.._band3, _scrapCluster, _junkCar, _scatter, _buildShed).
-- Original line cites are "World.js L~n".
--
-- RNG ORDER (spec pass-2 rule 5): the original spends 16,384 rng draws on a
-- per-cell ground layer (World.js L66-77). This port replaces ground with one
-- slab + 4 band tint strips + 3 road strips (DECIDED, docs/PORT-ARCHITECTURE.md
-- "Phase 1 simplifications"). The draw sequence therefore CANNOT match
-- World.js 1:1 — instead we re-seed a FRESH LCG(seed + 1) for everything
-- after the ground loop would have run (roads draw no rng; bands 0-3 and the
-- buried caches draw in the original order). Within this port the layout is
-- fully deterministic; that is what matters now.
--
-- PHASE 2 skips (spec rule 4, no rng draws lost — both are ground/landmark
-- passes that run after the cache draws we keep):
--   - _bandFlavor (World.js L145-155) — ground is tint strips now.
--   - _placeLandmarks named landmarks (World.js L136-143, landmarks.js
--     LANDMARKS) — stubbed; band generators already place stations/tracks.
--   - PLAQUES block placement in band3 (World.js L593-597) — positions only.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Blocks = require(Shared:WaitForChild("Blocks"))
local Config = require(Shared:WaitForChild("Config"))
local LCG = require(script.Parent:WaitForChild("LCG"))

local B = Blocks.B

local Wd = Config.MAP_SIZE    -- 128 (World.js L29 width)
local Dd = Config.MAP_SIZE    -- 128 (World.js L30 depth)
local Hd = Config.MAP_HEIGHT  -- 10  (World.js L31 height)

local YardBuilder = {}

-- spec rule 7: _setBlock never overwrites an interactive station / BEACON /
-- TRACK / BURIED_CACHE (World.js L129-134 `_lm` guard, applied to ALL writes
-- so scatter can't bury stations; otherwise later writes win, as in World.js).
local PROTECTED = {
	[B.WORKBENCH] = true,
	[B.FORGE] = true,
	[B.SMELTER] = true,
	[B.SCRAP_CANNON] = true, -- BLOCK_DEF.interactive (blocks.js)
	[B.BEACON] = true,
	[B.TRACK] = true,
	[B.BURIED_CACHE] = true,
}

-- spec rule 6 materials
local METAL_MATERIAL = {
	[B.RUST_METAL] = true, [B.CLEAN_METAL] = true, [B.WALL_METAL] = true,
	[B.ROOF_METAL] = true, [B.SCRAP_CANNON] = true,
}
local WOOD_MATERIAL = { [B.WOOD_PLANK] = true, [B.CRATE] = true }

-- spec rule 6: PointLight only for these three (caps total light count);
-- other emissive-looking blocks just get a brighter Color3.
local LIGHT_BLOCKS = { [B.FLOODLIGHT] = true, [B.BEACON] = true, [B.CRYSTAL_ORE] = true }
local BRIGHTEN = { [B.ACID_PUDDLE] = true, [B.HOT_SLAG] = true } -- hazards read as hot

local STATION_BLOCKS = { [B.WORKBENCH] = true, [B.FORGE] = true, [B.SMELTER] = true }

-- Band identity colors (World.js L21-26 BANDS / yard-bible) for the tint strips.
local BAND_COLORS = { 0x8B6914, 0x707070, 0x228822, 0x882222 }

-- plaques.js (positions only in Phase 1 — spec rule 4)
local PLAQUE_POSITIONS = {
	{ id = "sparky_ix",    x = 10, z = 18,  band = 0 },
	{ id = "zappa",        x = 58, z = 30,  band = 1 },
	{ id = "fizz",         x = 66, z = 44,  band = 1 },
	{ id = "insomniac",    x = 62, z = 70,  band = 2 },
	{ id = "humdinger",    x = 50, z = 88,  band = 2 },
	{ id = "picky",        x = 44, z = 78,  band = 2 },
	{ id = "northstar",    x = 76, z = 52,  band = 3 },
	{ id = "floater",      x = 74, z = 96,  band = 3 },
	{ id = "truthreader",  x = 80, z = 104, band = 3 },
	{ id = "hotplug",      x = 86, z = 108, band = 3 },
}

local function hexColor(hex)
	local r = bit32.band(bit32.rshift(hex, 16), 0xff)
	local g = bit32.band(bit32.rshift(hex, 8), 0xff)
	local b = bit32.band(hex, 0xff)
	return Color3.fromRGB(r, g, b)
end

-- ── Per-generation state (single-shot at server boot) ──────────────────────
local grid       -- x + z*W + y*W*D -> block id (World.js L41 _idx)
local landmarks  -- same shape as World.js this.landmarks
local level1     -- z*128+x -> block id at level 1 (WorldModel input, spec D2)
local partCount  -- block parts + ground parts

local function idx(x, y, z)
	return x + z * Wd + y * Wd * Dd
end

-- World.js L43-46 getBlock (out of bounds = AIR)
function YardBuilder._getBlock(x, y, z)
	if x < 0 or x >= Wd or z < 0 or z >= Dd or y < 0 or y >= Hd then return B.AIR end
	return grid[idx(x, y, z)] or B.AIR
end

-- World.js L48-54 setBlock + the spec rule 7 guard.
function YardBuilder._setBlock(x, y, z, id)
	if x < 0 or x >= Wd or z < 0 or z >= Dd or y < 0 or y >= Hd then return end
	local k = idx(x, y, z)
	local cur = grid[k]
	if cur ~= nil and PROTECTED[cur] then return end -- never bury stations/beacons/track/caches
	if id == B.AIR then grid[k] = nil else grid[k] = id end
end

-- Unguarded write, for Roblox-side additions only (Earl's gate, oval
-- floodlight towers) — the original's plain setBlock semantics (L48-54).
local function forceSet(x, y, z, id)
	if x < 0 or x >= Wd or z < 0 or z >= Dd or y < 0 or y >= Hd then return end
	if id == B.AIR then grid[idx(x, y, z)] = nil else grid[idx(x, y, z)] = id end
end

-- ── Band generator helpers (World.js L600-649) ─────────────────────────────

-- World.js L602-613 _scrapCluster. NOTE: the id ternary re-draws per level y
-- (it sits inside the y loop in the original) — draw order preserved.
local function scrapCluster(rng, cx, cz, maxH, radius)
	for dz = -radius, radius do
		for dx = -radius, radius do
			if rng:next() >= 0.4 then
				local h = 1 + math.floor(rng:next() * maxH)
				for y = 1, h do
					local id
					if rng:next() < 0.6 then
						id = B.SCRAP_PILE
					elseif rng:next() < 0.5 then
						id = B.RUST_METAL
					else
						id = B.CLEAN_METAL
					end
					YardBuilder._setBlock(cx + dx, y, cz + dz, id)
				end
			end
		end
	end
end

-- World.js L615-622 _junkCar
local function junkCar(rng, cx, cz)
	for dz = 0, 1 do
		for dx = 0, 2 do
			YardBuilder._setBlock(cx + dx, 1, cz + dz, B.JUNK_CAR)
			if rng:next() < 0.5 then
				YardBuilder._setBlock(cx + dx, 2, cz + dz, B.JUNK_CAR)
			end
		end
	end
end

-- World.js L624-630 _scatter
local function scatter(rng, id, count, x0, x1, z0, z1)
	for _ = 1, count do
		local x = x0 + math.floor(rng:next() * (x1 - x0))
		local z = z0 + math.floor(rng:next() * (z1 - z0))
		if YardBuilder._getBlock(x, 1, z) == B.AIR then
			YardBuilder._setBlock(x, 1, z, id)
		end
	end
end

-- World.js L632-649 _buildShed (the original takes rng but never draws from
-- it — dropped from the signature, draw order unaffected).
local function buildShed(x0, y0, z0, w, h, d)
	for y = y0 + 1, y0 + h - 1 do
		for dz = 0, d - 1 do
			YardBuilder._setBlock(x0, y, z0 + dz, B.WALL_METAL)
			YardBuilder._setBlock(x0 + w - 1, y, z0 + dz, B.WALL_METAL)
		end
		for dx = 1, w - 2 do
			YardBuilder._setBlock(x0 + dx, y, z0, B.WALL_METAL)
			YardBuilder._setBlock(x0 + dx, y, z0 + d - 1, B.WALL_METAL)
		end
	end
	for dz = 0, d - 1 do
		for dx = 0, w - 1 do
			YardBuilder._setBlock(x0 + dx, y0 + h, z0 + dz, B.ROOF_METAL)
		end
	end
	for dz = 1, d - 2 do
		for dx = 1, w - 2 do
			YardBuilder._setBlock(x0 + dx, y0, z0 + dz, B.CONCRETE)
		end
	end
end

-- ── Band 0: The Yard Gate (World.js L159-257) ──────────────────────────────
local function band0(rng)
	local z0, z1 = 0, 31

	-- Main station row near spawn (L163-168)
	YardBuilder._setBlock(12, 1, 8, B.WORKBENCH)
	YardBuilder._setBlock(14, 1, 8, B.FORGE)
	YardBuilder._setBlock(16, 1, 8, B.SMELTER)
	landmarks.workbench = { x = 12, y = 1, z = 8 }
	landmarks.forge     = { x = 14, y = 1, z = 8 }
	landmarks.smelter   = { x = 16, y = 1, z = 8 }

	-- Scrap Exchange board (L171-173)
	YardBuilder._setBlock(14, 1, 14, B.POWER_BOX)
	YardBuilder._setBlock(14, 2, 14, B.POWER_BOX)
	landmarks.exchange = { x = 14, y = 2, z = 14 }

	-- Concrete path from spawn to stations (L176-177) — level 0, renders flat
	for z = 3, 8 do YardBuilder._setBlock(10, 0, z, B.CONCRETE) end
	for x = 10, 17 do YardBuilder._setBlock(x, 0, 8, B.CONCRETE) end

	-- Starter shed (L180)
	buildShed(20, 0, 14, 7, 4, 6)

	-- World.js L183: 30 scrap clusters
	for _ = 1, 30 do
		local x = 2 + math.floor(rng:next() * (Wd - 4))
		local z = z0 + 2 + math.floor(rng:next() * (z1 - z0 - 4))
		scrapCluster(rng, x, z, 2, 2)
	end
	-- Oil drums (L189-196) — the second draw only happens when the cell was air
	for _ = 1, 20 do
		local x = math.floor(rng:next() * (Wd - 4)) + 2
		local z = z0 + math.floor(rng:next() * (z1 - z0))
		if YardBuilder._getBlock(x, 1, z) == B.AIR then
			YardBuilder._setBlock(x, 1, z, B.OIL_DRUM)
			if rng:next() < 0.4 then
				YardBuilder._setBlock(x, 2, z, B.OIL_DRUM)
			end
		end
	end
	-- World.js L198: 8 junk cars
	for _ = 1, 8 do
		local x = math.floor(rng:next() * (Wd - 6)) + 3
		local z = z0 + 5 + math.floor(rng:next() * (z1 - z0 - 6))
		junkCar(rng, x, z)
	end
	-- Crates, wood planks, power boxes (L204-206)
	scatter(rng, B.CRATE, 10, 2, Wd - 2, z0, z1)
	scatter(rng, B.WOOD_PLANK, 14, 2, Wd - 2, z0, z1)
	scatter(rng, B.POWER_BOX, 6, 2, Wd - 2, z0, z1)

	-- Second station cluster, far end x≈90 (L209-210)
	YardBuilder._setBlock(90, 1, 20, B.WORKBENCH)
	YardBuilder._setBlock(92, 1, 20, B.FORGE)

	-- Robot test track — rectangular loop (L213-214). Original writes y=0
	-- (ground overlay); the port renders level-0 blocks as flat strips.
	for x = 30, 46 do
		YardBuilder._setBlock(x, 0, 14, B.TRACK)
		YardBuilder._setBlock(x, 0, 22, B.TRACK)
	end
	for z = 14, 22 do
		YardBuilder._setBlock(30, 0, z, B.TRACK)
		YardBuilder._setBlock(46, 0, z, B.TRACK)
	end

	-- Start/finish gate arch (L217-220)
	for _, gx in ipairs({ 30, 46 }) do
		for y = 1, 3 do YardBuilder._setBlock(gx, y, 13, B.WALL_METAL) end
		YardBuilder._setBlock(gx, 4, 13, B.FLOODLIGHT)
	end
	-- Crossbar (L222)
	for x = 31, 45 do YardBuilder._setBlock(x, 4, 13, B.CLEAN_METAL) end

	-- Racing bleachers, east side of the test track (L225-232)
	for bz = 14, 22 do
		YardBuilder._setBlock(48, 1, bz, B.CONCRETE)
		YardBuilder._setBlock(48, 2, bz, B.WALL_METAL)
		YardBuilder._setBlock(49, 2, bz, B.CONCRETE)
		YardBuilder._setBlock(49, 3, bz, B.WALL_METAL)
		YardBuilder._setBlock(50, 3, bz, B.CONCRETE)
		YardBuilder._setBlock(50, 4, bz, B.WALL_METAL)
	end
	-- Bleacher supports (L234-237)
	for _, bz in ipairs({ 14, 22 }) do
		for y = 1, 4 do
			YardBuilder._setBlock(48, y, bz, B.WALL_METAL)
			YardBuilder._setBlock(50, y, bz, B.WALL_METAL)
		end
	end

	-- Junk-lantern breadcrumbs, spawn → Smelter (L243-256). Placed LAST in
	-- band 0 so scrap can't bury the trail; stale junk above is cleared.
	local trail = {
		{ x = 9,  z = 4 },
		{ x = 9,  z = 6 },
		{ x = 11, z = 7 },
		{ x = 13, z = 7 },
		{ x = 15, z = 7 },
	}
	landmarks.smelter_trail = {}
	for i, t in ipairs(trail) do
		landmarks.smelter_trail[i] = { x = t.x, z = t.z }
		YardBuilder._setBlock(t.x, 1, t.z, B.BEACON)
		if YardBuilder._getBlock(t.x, 2, t.z) ~= B.AIR then
			YardBuilder._setBlock(t.x, 2, t.z, B.AIR)
		end
	end
end

-- ── Band 1: Industrial Corridor (World.js L259-334) ────────────────────────
local function band1(rng)
	local z0, z1 = 32, 63

	-- World.js L263: 40 dense scrap clusters
	for _ = 1, 40 do
		local x = 2 + math.floor(rng:next() * (Wd - 4))
		local z = z0 + math.floor(rng:next() * (z1 - z0))
		scrapCluster(rng, x, z, 3, 3)
	end

	-- World.js L270: 18 metal towers (cross-beam draw only when h > 3, L277)
	for _ = 1, 18 do
		local x = 3 + math.floor(rng:next() * (Wd - 6))
		local z = z0 + 2 + math.floor(rng:next() * (z1 - z0 - 4))
		local h = 3 + math.floor(rng:next() * 4)
		local typ = B.RUST_METAL
		if rng:next() > 0.5 then typ = B.CLEAN_METAL end
		for y = 1, h do YardBuilder._setBlock(x, y, z, typ) end
		if h > 3 and rng:next() > 0.5 then
			for dx = -1, 1 do YardBuilder._setBlock(x + dx, h - 1, z, typ) end
		end
	end

	-- World.js L283: 10 oil refineries (4-tall drum stacks)
	for _ = 1, 10 do
		local cx = 4 + math.floor(rng:next() * (Wd - 8))
		local cz = z0 + 4 + math.floor(rng:next() * (z1 - z0 - 8))
		for c = 0, 2 do
			local bx = cx + c * 2
			for y = 1, 4 do YardBuilder._setBlock(bx, y, cz, B.OIL_DRUM) end
			if c < 2 then YardBuilder._setBlock(bx + 1, 3, cz, B.CLEAN_METAL) end
		end
	end

	-- World.js L294: 4 forge sheds
	for _ = 1, 4 do
		local x = 5 + math.floor(rng:next() * (Wd - 14))
		local z = z0 + 5 + math.floor(rng:next() * (z1 - z0 - 12))
		buildShed(x, 0, z, 6, 4, 5)
		YardBuilder._setBlock(x + 2, 1, z + 2, B.FORGE)
		YardBuilder._setBlock(x + 4, 1, z + 2, B.WORKBENCH)
	end

	-- World.js L303: 6 wide scrap walls
	for _ = 1, 6 do
		local z = z0 + 8 + math.floor(rng:next() * 18)
		local x0 = math.floor(rng:next() * 20)
		local len = 10 + math.floor(rng:next() * 15)
		local h = 1 + math.floor(rng:next() * 2)
		for dx = 0, len - 1 do
			for y = 1, h do
				local id = B.SCRAP_PILE
				if rng:next() > 0.5 then id = B.RUST_METAL end
				YardBuilder._setBlock(x0 + dx, y, z, id)
			end
		end
	end

	-- Band entry stations (L316-319)
	YardBuilder._setBlock(65, 1, 38, B.WORKBENCH)
	YardBuilder._setBlock(67, 1, 38, B.FORGE)
	YardBuilder._setBlock(69, 1, 38, B.SMELTER)
	landmarks.band1_stations = { x = 67, y = 1, z = 38 }

	-- World.js L322: 6 acid puddle hazard pools
	for _ = 1, 6 do
		local cx = 5 + math.floor(rng:next() * (Wd - 10))
		local cz = z0 + 4 + math.floor(rng:next() * (z1 - z0 - 8))
		for dz = -1, 1 do
			for dx = -2, 2 do
				if rng:next() >= 0.35 then
					if YardBuilder._getBlock(cx + dx, 1, cz + dz) == B.AIR then
						YardBuilder._setBlock(cx + dx, 1, cz + dz, B.ACID_PUDDLE)
					end
				end
			end
		end
	end
end

-- ── Band 2: Circuit City (World.js L336-471) ───────────────────────────────
local function band2(rng)
	local z0, z1 = 64, 95

	-- Power grid rows (L340-350); JS `gx < W - 5` step 8
	for gx = 5, Wd - 6, 8 do
		local z = z0 + 4 + math.floor(rng:next() * 20)
		YardBuilder._setBlock(gx, 1, z, B.POWER_BOX)
		YardBuilder._setBlock(gx, 2, z, B.POWER_BOX)
		if gx + 8 < Wd then
			for dx = 1, 6 do
				YardBuilder._setBlock(gx + dx, 3, z, B.CLEAN_METAL)
			end
		end
	end

	-- World.js L353: 5 electronics buildings
	for _ = 1, 5 do
		local x = 6 + math.floor(rng:next() * (Wd - 14))
		local z = z0 + 4 + math.floor(rng:next() * (z1 - z0 - 12))
		buildShed(x, 0, z, 8, 4, 7)
		for dx = 1, 6, 2 do
			local a = B.CRATE
			if rng:next() > 0.5 then a = B.POWER_BOX end
			local b = B.POWER_BOX
			if rng:next() > 0.5 then b = B.CRATE end
			YardBuilder._setBlock(x + dx, 1, z + 2, a)
			YardBuilder._setBlock(x + dx, 1, z + 4, b)
		end
	end

	-- World.js L365: 8 crate warehouses
	for _ = 1, 8 do
		local x = 3 + math.floor(rng:next() * (Wd - 8))
		local z = z0 + 3 + math.floor(rng:next() * (z1 - z0 - 6))
		local w = 2 + math.floor(rng:next() * 3)
		local h = 1 + math.floor(rng:next() * 3)
		for dx = 0, w - 1 do
			for y = 1, h do YardBuilder._setBlock(x + dx, y, z, B.CRATE) end
		end
	end

	-- Loose circuit-rich scrap (L376-378)
	scatter(rng, B.CRATE, 25, 2, Wd - 2, z0, z1)
	scatter(rng, B.POWER_BOX, 20, 2, Wd - 2, z0, z1)
	scatter(rng, B.SCRAP_PILE, 20, 2, Wd - 2, z0, z1)

	-- World.js L381: 4 acid runoff pools
	for _ = 1, 4 do
		local cx = 8 + math.floor(rng:next() * (Wd - 16))
		local cz = z0 + 8 + math.floor(rng:next() * (z1 - z0 - 16))
		for dz = -1, 1 do
			for dx = -2, 2 do
				if rng:next() >= 0.4 then
					if YardBuilder._getBlock(cx + dx, 1, cz + dz) == B.AIR then
						YardBuilder._setBlock(cx + dx, 1, cz + dz, B.ACID_PUDDLE)
					end
				end
			end
		end
	end

	-- Main band 2 station cluster (L395-398)
	YardBuilder._setBlock(60, 1, 76, B.WORKBENCH)
	YardBuilder._setBlock(62, 1, 76, B.FORGE)
	YardBuilder._setBlock(64, 1, 76, B.SMELTER)
	landmarks.band2_stations = { x = 62, y = 1, z = 76 }

	-- Advanced oval TRACK circuit (L402-410). Center (35, 84), radii 14 x 7
	-- (Config.OVAL). Original writes y=0; the port writes LEVEL 1 as a flat
	-- 4x0.4x4 ground strip (spec rule 8 — WorldModel treats TRACK as
	-- non-solid, so bots still roll over it like the original's y=0 track).
	local oCx, oCz, oRx, oRz = Config.OVAL.cx, Config.OVAL.cz, Config.OVAL.rx, Config.OVAL.rz
	for i = 0, 359 do
		local rad = (i * math.pi) / 180
		local ox = math.round(oCx + oRx * math.cos(rad))
		local oz = math.round(oCz + oRz * math.sin(rad))
		if ox >= 2 and ox < Wd - 2 and oz >= z0 and oz <= z1 then
			YardBuilder._setBlock(ox, 1, oz, B.TRACK)
		end
	end

	-- Circuit lab — larger building with all three stations (L413-416)
	buildShed(100, 0, 68, 10, 4, 8)
	YardBuilder._setBlock(102, 1, 72, B.WORKBENCH)
	YardBuilder._setBlock(104, 1, 72, B.FORGE)
	YardBuilder._setBlock(106, 1, 72, B.SMELTER)

	-- Radio / comms tower (L419-438)
	local tx, tz = 80, 71
	for y = 1, 9 do YardBuilder._setBlock(tx, y, tz, B.CLEAN_METAL) end
	for _, armY in ipairs({ 5, 7 }) do
		for d = -2, 2 do
			if d ~= 0 then
				YardBuilder._setBlock(tx + d, armY, tz, B.CLEAN_METAL)
				YardBuilder._setBlock(tx, armY, tz + d, B.CLEAN_METAL)
			end
		end
	end
	YardBuilder._setBlock(tx, 9, tz, B.POWER_BOX) -- blinking apex "beacon"
	for d = 1, 2 do
		YardBuilder._setBlock(tx + d, d, tz, B.WALL_METAL)
		YardBuilder._setBlock(tx - d, d, tz, B.WALL_METAL)
		YardBuilder._setBlock(tx, d, tz + d, B.WALL_METAL)
		YardBuilder._setBlock(tx, d, tz - d, B.WALL_METAL)
	end
	landmarks.radio_tower = { x = tx, y = 1, z = tz }

	-- Oval-track grandstand (L441-447)
	for bx = 21, 27 do
		YardBuilder._setBlock(bx, 1, 77, B.CONCRETE)
		YardBuilder._setBlock(bx, 2, 78, B.WALL_METAL)
		YardBuilder._setBlock(bx, 3, 79, B.WALL_METAL)
		YardBuilder._setBlock(bx, 3, 78, B.CONCRETE)
		YardBuilder._setBlock(bx, 4, 79, B.WALL_METAL)
	end
	for _, bx in ipairs({ 21, 27 }) do
		for y = 1, 4 do YardBuilder._setBlock(bx, y, 79, B.WALL_METAL) end
	end
	-- Grandstand floodlights (L453-454)
	YardBuilder._setBlock(22, 5, 79, B.FLOODLIGHT)
	YardBuilder._setBlock(26, 5, 79, B.FLOODLIGHT)

	-- Race board (L457-460)
	YardBuilder._setBlock(28, 1, 78, B.POWER_BOX)
	YardBuilder._setBlock(28, 2, 78, B.POWER_BOX)
	YardBuilder._setBlock(28, 3, 78, B.POWER_BOX)
	landmarks.race_board = { x = 28, y = 2, z = 78 }

	-- Rare crystal ore teaser clusters (L463-470)
	for _, c in ipairs({ { 55, 85 }, { 95, 72 } }) do
		local cx, cz = c[1], c[2]
		for dz = -1, 1 do
			for dx = -1, 1 do
				if rng:next() >= 0.6 then
					YardBuilder._setBlock(cx + dx, 1, cz + dz, B.CRYSTAL_ORE)
				end
			end
		end
	end
end

-- ── Band 3: The Deep Yard (World.js L473-598) ──────────────────────────────
local function band3(rng)
	local z0, z1 = 96, 127

	-- World.js L477: 80 extreme-chaos stacks (id/h draws only when cell air)
	local ids = { B.SCRAP_PILE, B.RUST_METAL, B.CRATE, B.OIL_DRUM, B.JUNK_CAR,
		B.CLEAN_METAL, B.POWER_BOX, B.WALL_METAL, B.WOOD_PLANK }
	for _ = 1, 80 do
		local x = 2 + math.floor(rng:next() * (Wd - 4))
		local z = z0 + 1 + math.floor(rng:next() * (z1 - z0 - 2))
		if YardBuilder._getBlock(x, 1, z) == B.AIR then
			local id = ids[math.floor(rng:next() * #ids) + 1]
			local h = 1 + math.floor(rng:next() * 3)
			for y = 1, h do YardBuilder._setBlock(x, y, z, id) end
		end
	end

	-- World.js L490: 18 junk cars (graveyard-dense)
	for _ = 1, 18 do
		local x = 3 + math.floor(rng:next() * (Wd - 6))
		local z = z0 + 5 + math.floor(rng:next() * (z1 - z0 - 8))
		junkCar(rng, x, z)
	end

	-- World.js L497: 12 tall metal ruins (5-8 high) with platforms
	for _ = 1, 12 do
		local x = 4 + math.floor(rng:next() * (Wd - 8))
		local z = z0 + 4 + math.floor(rng:next() * (z1 - z0 - 8))
		local h = 5 + math.floor(rng:next() * 4)
		local t = B.CLEAN_METAL
		if rng:next() > 0.5 then t = B.WALL_METAL end
		for y = 1, h do YardBuilder._setBlock(x, y, z, t) end
		for dx = -1, 1 do
			for dz = -1, 1 do
				YardBuilder._setBlock(x + dx, h, z + dz, B.CONCRETE)
			end
		end
	end

	-- Crashed plane silhouette (L509-513)
	local px, pz = 20, z0 + 10
	for dx = 0, 13 do YardBuilder._setBlock(px + dx, 2, pz, B.JUNK_CAR) end       -- fuselage
	for dx = -6, 6 do YardBuilder._setBlock(px + 7 + dx, 2, pz + 2, B.CLEAN_METAL) end -- wing
	for dx = -3, 3 do YardBuilder._setBlock(px + 7 + dx, 4, pz - 2, B.CLEAN_METAL) end -- tail
	for y = 2, 5 do YardBuilder._setBlock(px + 7, y, pz - 3, B.WALL_METAL) end   -- tail fin

	-- Mystery monument (L516-521)
	local mx, mz = 100, z0 + 20
	for y = 1, 8 do YardBuilder._setBlock(mx, y, mz, B.CLEAN_METAL) end
	for d = -2, 2 do
		YardBuilder._setBlock(mx + d, 8, mz, B.SCRAP_PILE)
		YardBuilder._setBlock(mx, 8, mz + d, B.SCRAP_PILE)
	end

	-- THE FINAL WORKSHOP (L524-532)
	buildShed(50, 0, z0 + 20, 12, 5, 10)
	YardBuilder._setBlock(52, 1, z0 + 25, B.WORKBENCH)
	YardBuilder._setBlock(54, 1, z0 + 25, B.FORGE)
	YardBuilder._setBlock(56, 1, z0 + 25, B.SMELTER)
	YardBuilder._setBlock(58, 1, z0 + 25, B.WORKBENCH)
	YardBuilder._setBlock(52, 1, z0 + 27, B.CRATE)
	YardBuilder._setBlock(54, 1, z0 + 27, B.POWER_BOX)
	YardBuilder._setBlock(56, 1, z0 + 27, B.OIL_DRUM)
	landmarks.final_workshop = { x = 56, y = 1, z = z0 + 25 }

	-- Scatter (L535-536)
	scatter(rng, B.CRATE, 20, 2, Wd - 2, z0, z1)
	scatter(rng, B.POWER_BOX, 15, 2, Wd - 2, z0, z1)

	-- World.js L539: 8 hot slag pools (the `by` draw happens even when the
	-- target cell is occupied — L545-546 — preserved)
	for _ = 1, 8 do
		local sx = 3 + math.floor(rng:next() * (Wd - 6))
		local sz = z0 + 3 + math.floor(rng:next() * (z1 - z0 - 6))
		for dz = -1, 1 do
			for dx = -2, 2 do
				if rng:next() >= 0.5 then
					local by = 1 + math.floor(rng:next() * 2)
					if YardBuilder._getBlock(sx + dx, by, sz + dz) == B.AIR then
						YardBuilder._setBlock(sx + dx, by, sz + dz, B.HOT_SLAG)
					end
				end
			end
		end
	end

	-- Crystal ore clusters (L554-567) — the deep-yard veins
	local crystalSeeds = {
		{ 15, z0 + 8 }, { 35, z0 + 14 }, { 60, z0 + 6 }, { 88, z0 + 16 },
		{ 112, z0 + 11 }, { 45, z0 + 22 }, { 75, z0 + 28 }, { 8, z0 + 4 },
		{ 50, z0 + 15 }, { 95, z0 + 26 }, { 118, z0 + 10 }, { 28, z0 + 18 },
		{ 70, z0 + 12 }, { 105, z0 + 24 },
	}
	for _, c in ipairs(crystalSeeds) do
		local cx, cz = c[1], c[2]
		for dz = -2, 2 do
			for dx = -2, 2 do
				if rng:next() >= 0.45 then
					local y = 1 + math.floor(rng:next() * 2)
					YardBuilder._setBlock(cx + dx, y, cz + dz, B.CRYSTAL_ORE)
				end
			end
		end
	end
	landmarks.crystal_cave = { x = crystalSeeds[1][1], y = 1, z = crystalSeeds[1][2] }

	-- Scattered scrap cannons (L570)
	scatter(rng, B.SCRAP_CANNON, 5, 2, Wd - 2, z0, z1)

	-- Robot graveyard — 8 decommissioned bots in a 4x2 grid (L573-588)
	for i = 0, 7 do
		local gx = 72 + (i % 4) * 4
		local gz = z0 + 4 + math.floor(i / 4) * 7
		local lean = 0
		if i % 3 == 0 then lean = 1 end -- some are tilted (collapsed)
		for y = 1, 2 do YardBuilder._setBlock(gx, y, gz, B.RUST_METAL) end -- body
		YardBuilder._setBlock(gx + lean, 3, gz, B.SCRAP_PILE)                -- head
		YardBuilder._setBlock(gx - 1, 2, gz, B.RUST_METAL)                   -- arms
		YardBuilder._setBlock(gx + 1, 2, gz, B.RUST_METAL)
		YardBuilder._setBlock(gx, 1, gz - 1, B.RUST_METAL)                   -- legs
		YardBuilder._setBlock(gx, 1, gz + 1, B.RUST_METAL)
	end
	landmarks.robot_graveyard = { x = 79, y = 1, z = z0 + 7 }

	-- PHASE 2: plaque block placement (World.js L593-597: RUST_METAL post +
	-- CLEAN_METAL board per plaque) skipped per spec rule 4 — positions only.
	landmarks.plaques = PLAQUE_POSITIONS
end

-- ── Parts ──────────────────────────────────────────────────────────────────

local function makeBlockPart(parentFolder, x, y, z, id)
	local def = Blocks.DEF[id]
	local part = Instance.new("Part")
	part.Name = def.name
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	local sx, sz = Config.cellToStud(x, z)
	local isStation = STATION_BLOCKS[id] == true
	if y == 0 or id == B.TRACK then
		-- spec rule 8: track strips + level-0 markings are flat ground strips
		-- (4x0.4x4, center Y=0.2, walk-over-able)
		part.Size = Vector3.new(Config.CELL, 0.4, Config.CELL)
		part.CFrame = CFrame.new(sx, 0.2, sz)
		part.CanCollide = false
	elseif isStation then
		-- spec rule 6: stations are squat 4x3x4 (cosmetic; cell still occupied)
		part.Size = Vector3.new(Config.CELL, 3, Config.CELL)
		part.CFrame = CFrame.new(sx, (y - 1) * Config.CELL + 1.5, sz)
		part.CanCollide = Blocks.isSolid(id)
	else
		part.Size = Vector3.new(Config.CELL, Config.CELL, Config.CELL)
		part.CFrame = CFrame.new(sx, Config.levelToStudY(y), sz)
		part.CanCollide = Blocks.isSolid(id) -- hazard puddles/slag: nonSolid -> false
	end

	if METAL_MATERIAL[id] then
		part.Material = Enum.Material.Metal
	elseif WOOD_MATERIAL[id] then
		part.Material = Enum.Material.Wood
	else
		part.Material = Enum.Material.Plastic
	end

	-- spec rule 6: FLOODLIGHT/BEACON/CRYSTAL_ORE get a real PointLight; other
	-- emissive-looking blocks lerp 30% toward white instead.
	local color = hexColor(def.color)
	local lit = LIGHT_BLOCKS[id] and def.emissive ~= nil
	if not lit and (def.emissive ~= nil or BRIGHTEN[id]) then
		color = color:Lerp(Color3.new(1, 1, 1), 0.3)
	end
	part.Color = color
	if lit then
		local light = Instance.new("PointLight")
		light.Color = hexColor(def.emissive)
		light.Range = 10
		light.Brightness = 1.5
		light.Parent = part
	end

	CollectionService:AddTag(part, "Block")
	if Blocks.isMineable(id) then CollectionService:AddTag(part, "Mineable") end
	if isStation then
		CollectionService:AddTag(part, "Station")
		part:SetAttribute("Station", def.station)
	end
	part:SetAttribute("BlockId", id)
	part:SetAttribute("X", x)
	part:SetAttribute("Z", z)
	part:SetAttribute("Level", y)
	part.Parent = parentFolder
	partCount = partCount + 1
end

-- spec rule 5: slab + 4 band tint strips + 3 road strips replace the per-cell
-- ground layer and _bandFlavor (docs/PORT-ARCHITECTURE.md "Phase 1
-- simplifications" — zero mechanical loss: ground blocks have no drops).
local function buildGround(parent)
	local groundFolder = Instance.new("Folder")
	groundFolder.Name = "Ground"

	-- One 512x512-stud slab, smooth gray-green (Roblox-side color pick), top
	-- at Y=0, Anchored.
	local slab = Instance.new("Part")
	slab.Name = "GroundSlab"
	slab.Size = Vector3.new(512, 1, 512)
	slab.CFrame = CFrame.new(0, -0.5, 0)
	slab.Anchored = true
	slab.Material = Enum.Material.SmoothPlastic
	slab.Color = hexColor(0x6e7a5a)
	slab.TopSurface = Enum.SurfaceType.Smooth
	slab.BottomSurface = Enum.SurfaceType.Smooth
	slab.Parent = groundFolder
	partCount = partCount + 1

	-- Four band tint strips, subtle (transparency ~0.7), band colors from
	-- World.js L21-26 BANDS. 0.2 thick, center Y=0.01 (spec rule 5).
	for i, band in ipairs(Config.BANDS) do
		local strip = Instance.new("Part")
		strip.Name = "BandTint" .. (i - 1)
		local depth = (band.z1 - band.z0 + 1) * Config.CELL
		strip.Size = Vector3.new(512, 0.2, depth)
		local cz = Config.MAP_ORIGIN + (band.z0 * Config.CELL + (band.z1 + 1) * Config.CELL) / 2
		strip.CFrame = CFrame.new(0, 0.01, cz)
		strip.Anchored = true
		strip.CanCollide = false
		strip.Transparency = 0.7
		strip.Material = Enum.Material.SmoothPlastic
		strip.Color = hexColor(BAND_COLORS[i])
		strip.TopSurface = Enum.SurfaceType.Smooth
		strip.BottomSurface = Enum.SurfaceType.Smooth
		strip.Parent = groundFolder
		partCount = partCount + 1
	end

	-- Three road strips (World.js L80-86: 3-wide concrete at x=8/64/120),
	-- concrete #888880, 3 cells = 12 studs wide, full 512 studs of Z. Center
	-- Y=0.02 so they read just above the tint strips (no z-fighting).
	for _, rx in ipairs(Config.ROADS_X) do
		local road = Instance.new("Part")
		road.Name = "Road" .. rx
		road.Size = Vector3.new(3 * Config.CELL, 0.2, 512)
		local cx = Config.cellToStud(rx, 0)
		road.CFrame = CFrame.new(cx, 0.02, 0)
		road.Anchored = true
		road.CanCollide = false
		road.Material = Enum.Material.Concrete
		road.Color = hexColor(0x888880)
		road.TopSurface = Enum.SurfaceType.Smooth
		road.BottomSurface = Enum.SurfaceType.Smooth
		road.Parent = groundFolder
		partCount = partCount + 1
	end

	groundFolder.Parent = parent
end

-- ── generate ───────────────────────────────────────────────────────────────

-- Returns { landmarks = {workbench={x=,z=}, ...}, level1 = {...}, partCount = n }
function YardBuilder.generate(parent, seed)
	seed = seed or Config.SEED -- World.js L59: generate(seed = 42)
	grid = {}
	landmarks = {}
	level1 = {}
	partCount = 0

	-- PHASE 1 ground simplification (spec rule 5): slab + tints + road
	-- strips. The original's 16,384-draw ground loop (World.js L66-77) is
	-- skipped, so we re-seed a FRESH LCG(seed + 1) for everything after it —
	-- the rng sequence no longer matches World.js; determinism within the
	-- port is what matters now.
	buildGround(parent)
	local rng = LCG.new(seed + 1)

	-- Phase order as World.js L88-98: band0 -> band1 -> band2 -> band3
	band0(rng)
	band1(rng)
	band2(rng)
	band3(rng)

	-- Roblox-side addition (spec rule 8): 4 floodlight towers at the oval's
	-- cardinal points — the floodlit oval from the bible. 6-tall WALL_METAL
	-- column + FLOODLIGHT on top. forceSet so a tower base can sit on the
	-- track ring (towers are solid; the ring reads as running under them).
	for _, p in ipairs({ { 21, 84 }, { 49, 84 }, { 35, 76 }, { 35, 92 } }) do
		for y = 1, 6 do forceSet(p[1], y, p[2], B.WALL_METAL) end
		forceSet(p[1], 7, p[2], B.FLOODLIGHT)
	end

	-- Roblox-side addition (spec rule 9): Earl's gate — bible: EARL'S SALVAGE
	-- & SCRAP, EST. WHENEVER. Arch across the x=8 road at z=3: two 4-tall
	-- WALL_METAL pylons at cells (6,3) and (10,3), WOOD_PLANK crossbar row at
	-- level 4, BEACON on each pylon top.
	for _, gx in ipairs({ 6, 10 }) do
		for y = 1, 4 do forceSet(gx, y, 3, B.WALL_METAL) end
		forceSet(gx, 5, 3, B.BEACON)
	end
	for x = 7, 9 do forceSet(x, 4, 3, B.WOOD_PLANK) end

	-- Buried signal caches (World.js L100-119) — six, one per sub-area.
	-- Draw order exactly as the original cacheSeeds literal.
	local cacheSeeds = {
		{ 20 + math.floor(rng:next() * 80),  10 + math.floor(rng:next() * 16) }, -- band 0
		{ 10 + math.floor(rng:next() * 100), 32 + math.floor(rng:next() * 26) }, -- band 1 a
		{ 10 + math.floor(rng:next() * 100), 40 + math.floor(rng:next() * 20) }, -- band 1 b
		{ 10 + math.floor(rng:next() * 100), 64 + math.floor(rng:next() * 26) }, -- band 2 a
		{ 10 + math.floor(rng:next() * 100), 72 + math.floor(rng:next() * 20) }, -- band 2 b
		{ 10 + math.floor(rng:next() * 100), 96 + math.floor(rng:next() * 28) }, -- band 3
	}
	for _, c in ipairs(cacheSeeds) do
		local bx = math.min(125, math.max(2, c[1]))
		local bz = math.min(125, math.max(2, c[2]))
		-- guard note: if a TRACK strip already owns this level-0 cell the
		-- cache write is skipped (spec rule 7) — a rare, accepted divergence.
		YardBuilder._setBlock(bx, 0, bz, B.BURIED_CACHE)
		if YardBuilder._getBlock(bx, 1, bz) == B.AIR then YardBuilder._setBlock(bx, 1, bz, B.DIRT) end
		if YardBuilder._getBlock(bx, 2, bz) == B.AIR then YardBuilder._setBlock(bx, 2, bz, B.CONCRETE) end
	end

	-- PHASE 2: _bandFlavor (World.js L122/L145-155) — replaced by tint strips.
	-- PHASE 2: _placeLandmarks named landmarks (World.js L125/L136-143,
	-- landmarks.js LANDMARKS) — stub; band generators already placed the
	-- stations, tracks, beacons and towers above.
	landmarks.named = {}

	-- spec rule 10: nothing may trap spawn — clear every block in cells
	-- (7..9, 4..6) at all levels AFTER generation. This intentionally eats
	-- the first two smelter-trail lanterns at (9,4) and (9,6) (World.js
	-- L243-249): spawn safety wins.
	for x = 7, 9 do
		for z = 4, 6 do
			for y = 0, Hd - 1 do
				forceSet(x, y, z, B.AIR)
			end
		end
	end

	-- Spawn point (spec rule 10): SpawnLocation at cell (8,5) center,
	-- 4x1x4, top at Y=0.5, transparent-ish concrete.
	local spx, spz = Config.cellToStud(8, 5)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "YardSpawn"
	spawn.Size = Vector3.new(4, 1, 4)
	spawn.CFrame = CFrame.new(spx, 0, spz)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Transparency = 0.25
	spawn.Material = Enum.Material.Concrete
	spawn.Color = hexColor(0x888880)
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.Parent = parent

	-- Materialize: one Part per block (spec rule 6), under parent.Blocks.
	local blocksFolder = Instance.new("Folder")
	blocksFolder.Name = "Blocks"
	for y = 0, Hd - 1 do
		for z = 0, Dd - 1 do
			for x = 0, Wd - 1 do
				local id = grid[idx(x, y, z)]
				if id ~= nil and id ~= B.AIR then
					makeBlockPart(blocksFolder, x, y, z, id)
					if y == 1 then
						level1[z * Wd + x] = id -- WorldModel input (spec D2)
					end
				end
			end
		end
	end
	blocksFolder.Parent = parent

	return { landmarks = landmarks, level1 = level1, partCount = partCount }
end

return YardBuilder
