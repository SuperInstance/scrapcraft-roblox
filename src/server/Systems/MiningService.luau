--!strict
-- MiningService.luau — server-authoritative port of Game.js mining
-- (_updateMine L1156–1184, _completeMine drops L1186–1216, lucky find
-- L1223–1243). The hold loop is CLIENT-side for responsiveness; the server
-- validates reach + hold duration and decides the outcome on finish.
--
-- Protocol (RemoteEvent "ScrapcraftMine"):
--   client → server : { type = "begin",  part = Instance }
--                     { type = "finish", part = Instance }
--   server → client : { type = "mined", id, drops = {{itemId, qty}, ...},
--                       lucky = itemId? }

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared:WaitForChild("Net"))
local Config = require(Shared:WaitForChild("Config"))
local Blocks = require(Shared:WaitForChild("Blocks"))

-- WorldModel contract (built in the parallel worldgen pass):
--   WorldModel.removeBlock(x, z, level) destroys the part, returns it.
local WorldModel = require(script.Parent.WorldModel)
local DayNightService = require(script.Parent.DayNightService)
local InventoryService = require(script.Parent.InventoryService)

local MiningService = {}

-- Server RNG member (spec Deliverable 3.3).
local rng = Random.new()

-- Debounce: one active mine per player. { part, startedAt }.
-- "Cancel if part changes": a new begin simply replaces the entry.
local active: {[Player]: {part: BasePart, startedAt: number}} = {}

local REACH = Config.MINE_REACH_STUDS + 6 -- latency slack (spec)

local function characterDistance(player: Player, part: BasePart): number?
	local character = player.Character
	if character == nil then return nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then return nil end
	return (root.Position - part.Position).Magnitude
end

local function validate(player: Player, part: BasePart): boolean
	if not part:IsA("BasePart") then return false end
	if part.Parent == nil then return false end -- already mined
	if not CollectionService:HasTag(part, "Mineable") then return false end
	if part:GetAttribute("BlockId") == nil then return false end
	local dist = characterDistance(player, part)
	if dist == nil or dist > REACH then return false end
	return true
end

function MiningService.beginMine(player: Player, part: BasePart): ()
	if not validate(player, part) then return end
	-- Debounce/cancel: replaces any previous entry (target changed → reset).
	active[player] = { part = part, startedAt = os.clock() }
end

function MiningService.finishMine(player: Player, part: BasePart): ()
	local entry = active[player]
	active[player] = nil
	if entry == nil or entry.part ~= part then return end
	if not validate(player, part) then return end -- incl. already-mined: silent

	local id = part:GetAttribute("BlockId") :: number
	local def = Blocks.DEF[id]
	if def == nil or def.hardness == nil then return end

	-- Hold-duration check: client accumulates progress += dt/hardness
	-- (Game.js L1171); allow 10% tolerance for latency.
	local elapsed = os.clock() - entry.startedAt
	if elapsed < def.hardness * 0.9 then return end

	local x = part:GetAttribute("X") :: number
	local z = part:GetAttribute("Z") :: number
	local level = part:GetAttribute("Level") :: number
	if typeof(x) ~= "number" or typeof(z) ~= "number" or typeof(level) ~= "number" then
		return
	end

	-- 1. Remove from the world model (level-1 grid sync) and destroy the
	--    part. WorldModel.removeBlock only owns level-1 occupancy + its part
	--    lookup, so stacked blocks (level ≥ 2) are destroyed here directly
	--    (Destroy on an already-destroyed part is a no-op).
	WorldModel.removeBlock(x, z, level)
	part:Destroy()

	-- 2. Roll drops — Game.js L1212–1216 exactly: primary `drop` at
	--    `dropChance` (qty = def.dropQty or 1), then `altDrop` at
	--    `altDropChance` (qty 1).
	local drops: {{itemId: string, qty: number}} = {}
	if def.drop ~= nil and def.dropChance ~= nil and rng:NextNumber() < def.dropChance then
		local qty = def.dropQty or 1
		InventoryService.add(player, def.drop, qty)
		table.insert(drops, { itemId = def.drop, qty = qty })
	end
	if def.altDrop ~= nil and def.altDropChance ~= nil and rng:NextNumber() < def.altDropChance then
		InventoryService.add(player, def.altDrop, 1)
		table.insert(drops, { itemId = def.altDrop, qty = 1 })
	end

	-- 3. Lucky find — Game.js L1226–1232: junk blocks, 8% night / 3% day,
	--    one random entry of LUCKY_LOOT.
	local lucky: string? = nil
	if Blocks.LUCKY_BLOCKS[id] then
		local chance = DayNightService.isNight()
			and Config.LUCKY_CHANCE_NIGHT
			or Config.LUCKY_CHANCE_DAY
		if rng:NextNumber() < chance then
			lucky = Blocks.LUCKY_LOOT[rng:NextInteger(1, #Blocks.LUCKY_LOOT)]
			InventoryService.add(player, lucky, 1)
		end
	end

	-- 4. UI feedback.
	Net.remote("Mine"):FireClient(player, {
		type = "mined",
		id = id,
		drops = drops,
		lucky = lucky,
	})
end

function MiningService.init(): ()
	local remote = Net.remote("Mine")
	remote.OnServerEvent:Connect(function(player: Player, msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg :: {type: string?, part: unknown?}
		if typeof(m.part) ~= "Instance" then return end
		local part = m.part :: BasePart
		if m.type == "begin" then
			MiningService.beginMine(player, part)
		elseif m.type == "finish" then
			MiningService.finishMine(player, part)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		active[player] = nil
	end)
end

return MiningService
