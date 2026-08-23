--!strict
-- WorldModel.luau — the yard's logical model AFTER generation: the bot's
-- physics oracle. Level-1 occupancy grid + sonar raycast.
--
-- Port of maker/GameWorldAdapter.js:
--   isSolidAt     L45-47  (world.isSolidAt(floor(x), 1, floor(z)))
--   distanceAhead L89-108 (24-step ray, range SONAR_RANGE,
--                          raw = max(0, (t - 0.25) / range) on first hit
--                          else 1; weather/storm noise L101-106 is PHASE 2)
-- sensorRangeMult = 1 in Phase 1 (no Wide-Angle Sensors upgrade yet).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Blocks = require(Shared:WaitForChild("Blocks"))
local Config = require(Shared:WaitForChild("Config"))

local B = Blocks.B
local SIZE = Config.MAP_SIZE -- 128

local WorldModel = {}

local grid = {}    -- z*128+x -> level-1 block id (0-based key, spec D2)
local partAt = {}  -- z*128+x -> BasePart for level-1 blocks (mining destroys)
local spawnX = 12  -- fallback: main bench (12,8), bot spawns 2 cells south
local spawnZ = 10

local function key(x, z)
	return z * SIZE + x
end

-- Call after YardBuilder.generate; copies its level-1 id array (spec D2).
function WorldModel.init(level1)
	for k, id in pairs(level1) do
		grid[k] = id
	end

	-- partAt lookup so removeBlock can destroy the rendered Part too.
	for _, inst in ipairs(CollectionService:GetTagged("Block")) do
		if inst:GetAttribute("Level") == 1 then
			local x = inst:GetAttribute("X")
			local z = inst:GetAttribute("Z")
			if type(x) == "number" and type(z) == "number" then
				partAt[key(x, z)] = inst
			end
		end
	end

	-- Bot spawn (spec D2): 2 cells south (+Z) of the workbench. Multiple
	-- workbenches exist; the spawn bench is the lowest-z one — the band-0
	-- main station row (World.js L163-166).
	local bestX, bestZ = nil, nil
	for _, inst in ipairs(CollectionService:GetTagged("Station")) do
		if inst:GetAttribute("Station") == "workbench" then
			local x = inst:GetAttribute("X")
			local z = inst:GetAttribute("Z")
			if type(x) == "number" and type(z) == "number" then
				if bestZ == nil or z < bestZ then
					bestX, bestZ = x, z
				end
			end
		end
	end
	if bestX ~= nil then
		spawnX = bestX
		spawnZ = bestZ + 2
	end
end

local function solidId(id)
	if id == nil or id == B.AIR then return false end
	-- TRACK renders as a 0.4-stud ground strip (spec rule 8); bots roll over
	-- it. Mirrors the original, where track lived at y=0 while isSolidAt
	-- checked level 1 only (GameWorldAdapter.js L46).
	if id == B.TRACK then return false end
	return Blocks.isSolid(id)
end

-- floor(x), LEVEL 1 ONLY (bots roll on the ground).
function WorldModel.isSolidAt(x, z)
	return solidId(grid[key(math.floor(x), math.floor(z))])
end

-- Sync on block add/remove. Only level-1 occupancy is tracked (spec D2).
function WorldModel.setSolid(x, z, level, id)
	if level ~= 1 then return end
	local k = key(math.floor(x), math.floor(z))
	if id == nil or id == B.AIR then grid[k] = nil else grid[k] = id end
end

-- GameWorldAdapter.js L89-108 verbatim minus weather noise (PHASE 2: storm
-- interference L101-106 — no weather system in Phase 1).
function WorldModel.distanceAhead(x, z, heading)
	local dx = math.sin(heading)
	local dz = math.cos(heading)
	local range = Config.SONAR_RANGE -- * sensorRangeMult (1 in Phase 1)
	local stepN = 24
	local raw = 1
	for i = 1, stepN do
		local t = (i / stepN) * range
		if WorldModel.isSolidAt(x + dx * t, z + dz * t) then
			raw = math.max(0, (t - 0.25) / range)
			break
		end
	end
	return raw
end

-- MiningService calls this (spec D2). PHASE 2: gravity pass — blocks above a
-- mined cell do NOT fall in Phase 1; WorldModel tracks level 1 anyway.
function WorldModel.removeBlock(x, z, level)
	if level ~= 1 then return end
	local k = key(math.floor(x), math.floor(z))
	grid[k] = nil
	local part = partAt[k]
	if part ~= nil then
		partAt[k] = nil
		part:Destroy()
	end
end

-- Bot spawn near the bench (yard cell coords; BotService converts to studs).
function WorldModel.getSpawn()
	return spawnX, spawnZ
end

return WorldModel
