--!strict
-- CraftingService.luau — ProximityPrompt stations + server-validated crafting.
-- Station parts (tag "Station", attribute Station = workbench|forge|smelter,
-- placed by YardBuilder) get a ProximityPrompt; triggering opens the craft
-- menu over the ScrapcraftCraft RemoteEvent. Craft requests are validated
-- against Recipes + InventoryService (tool gate, ingredients all-or-nothing).

local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared:WaitForChild("Net"))
local Recipes = require(Shared:WaitForChild("Recipes"))

local InventoryService = require(script.Parent.InventoryService)

local CraftingService = {}

local STATION_NAMES = {
	workbench = "Workbench",
	forge = "Forge",
	smelter = "Smelter",
	scrap_cannon = "Scrap Cannon",
}

local function stationName(station: string): string
	return STATION_NAMES[station] or station
end

local function addPrompt(inst: Instance): ()
	if not inst:IsA("BasePart") then return end
	local part = inst
	if part:FindFirstChildOfClass("ProximityPrompt") ~= nil then return end
	local station = part:GetAttribute("Station")
	if typeof(station) ~= "string" then return end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Craft"
	prompt.ObjectText = stationName(station)
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 10
	prompt.Parent = part

	-- One shared handler: trigger → open menu with the station's recipes
	-- (recipe list only; tooling state lives in the inventory snapshot).
	prompt.Triggered:Connect(function(player: Player)
		Net.remote("Craft"):FireClient(player, {
			type = "open",
			station = station,
			recipes = Recipes.forStation(station),
		})
	end)
end

local function craft(player: Player, recipeId: unknown): ()
	if typeof(recipeId) ~= "string" then return end
	local recipe = Recipes.get(recipeId)
	if recipe == nil then
		Net.remote("Craft"):FireClient(player, { type = "failed", reason = "Unknown recipe." })
		return
	end

	-- Tool gate (spec: recipe.tool → InventoryService.has). Station match is
	-- irrelevant in Phase 1 — the menu only offers valid ones.
	if recipe.tool ~= nil and not InventoryService.has(player, recipe.tool, 1) then
		local toolName = recipe.tool
		Net.remote("Craft"):FireClient(player, {
			type = "failed",
			reason = ("You need a %s for this."):format(toolName),
		})
		return
	end

	-- Check every ingredient first, then consume (all-or-nothing).
	for itemId, qty in pairs(recipe.ingredients) do
		if not InventoryService.has(player, itemId, qty) then
			Net.remote("Craft"):FireClient(player, {
				type = "failed",
				reason = "Not enough materials.",
			})
			return
		end
	end
	for itemId, qty in pairs(recipe.ingredients) do
		InventoryService.consume(player, itemId, qty)
	end

	InventoryService.add(player, recipe.output, recipe.qty)

	Net.remote("Craft"):FireClient(player, {
		type = "crafted",
		output = recipe.output,
		qty = recipe.qty,
		quip = recipe.quip,
	})
end

function CraftingService.init(): ()
	-- Stations exist before init (YardBuilder ran), but tag-added keeps it
	-- robust for later spawns/sync reloads.
	CollectionService:GetInstanceAddedSignal("Station"):Connect(addPrompt)
	for _, inst in ipairs(CollectionService:GetTagged("Station")) do
		addPrompt(inst)
	end

	Net.remote("Craft").OnServerEvent:Connect(function(player: Player, msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg :: {type: string?, recipeId: unknown?}
		if m.type == "craft" then
			craft(player, m.recipeId)
		end
	end)
end

return CraftingService
