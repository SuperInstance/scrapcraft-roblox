--!strict
-- InventoryService.luau — server-authoritative player inventories.
-- Phase 1 simple: one counter per item id, no stacks (spec Deliverable 2).
-- Broadcasts the full inventory to its owning player only, via the
-- ScrapcraftInv RemoteEvent, as { type = "inv", items = {...} }.

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

local InventoryService = {}

-- {[Player]: {[itemId]: count}}
local inventories: {[Player]: {[string]: number}} = {}

--- The live server-side inventory table (create on PlayerAdded).
function InventoryService.get(player: Player): {[string]: number}
	local inv = inventories[player]
	if inv == nil then
		inv = {}
		inventories[player] = inv
	end
	return inv
end

function InventoryService.count(player: Player, itemId: string): number
	local inv = inventories[player]
	if inv == nil then return 0 end
	return inv[itemId] or 0
end

function InventoryService.has(player: Player, itemId: string, qty: number): boolean
	return InventoryService.count(player, itemId) >= qty
end

local function sync(player: Player): ()
	Net.remote("Inv"):FireClient(player, {
		type = "inv",
		items = InventoryService.get(player),
	})
end

--- Add qty of itemId; returns the {itemId, delta} sync list for the client.
function InventoryService.add(player: Player, itemId: string, qty: number): {{itemId: string, delta: number}}
	local inv = InventoryService.get(player)
	inv[itemId] = (inv[itemId] or 0) + qty
	sync(player)
	return { { itemId = itemId, delta = qty } }
end

--- All-or-nothing consume; true if the items were taken.
function InventoryService.consume(player: Player, itemId: string, qty: number): boolean
	if not InventoryService.has(player, itemId, qty) then
		return false
	end
	local inv = InventoryService.get(player)
	local left = (inv[itemId] or 0) - qty
	if left > 0 then
		inv[itemId] = left
	else
		inv[itemId] = nil
	end
	sync(player)
	return true
end

function InventoryService.init(): ()
	Players.PlayerAdded:Connect(function(player: Player)
		InventoryService.get(player) -- create
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		inventories[player] = nil
	end)
	-- Players already present (e.g. late service start / sync reload).
	for _, player in ipairs(Players:GetPlayers()) do
		InventoryService.get(player)
	end
end

return InventoryService
