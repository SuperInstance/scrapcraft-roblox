--!strict
-- BrainEditorService.luau — Phase 2 server half of the visual brain editor.
-- The bench gets a second ProximityPrompt ("Build a Brain") that opens the
-- client-side tile editor (client/BrainEditor.luau). SAVE & RUN sends the
-- serialized program here; we validate with BrainDoc.validate (whitelist,
-- clamps, node/depth caps — never trust the wire) then hand the program to
-- BotService.attachCustomBrain, which keeps the module→brain economy.
--
-- Session memory: each player's last edited program (per server session).
-- PlayerDataService (Phase 2 persistence) persists it across sessions via
-- getEditorProgram/setEditorProgram hooks if it initialized first.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local BrainDoc = require(Shared:WaitForChild("BrainDoc"))
local TileProgram = require(Shared:WaitForChild("TileProgram"))

local BotService = require(script.Parent.BotService)

local BrainEditorService = {}

-- {[Player]: programTable}
local sessionPrograms: {[Player]: any} = {}

-- Optional persistence hooks (set by PlayerDataService.init when present).
local PlayerDataService: any = nil

function BrainEditorService.setPersistence(pds: any)
	PlayerDataService = pds
end

function BrainEditorService.getEditorProgram(player: Player): any
	if PlayerDataService ~= nil then
		local persisted = PlayerDataService.getEditorProgram(player)
		if type(persisted) == "table" then return persisted end
	end
	return sessionPrograms[player]
end

local function saveEditorProgram(player: Player, program: any)
	sessionPrograms[player] = program
	if PlayerDataService ~= nil then
		PlayerDataService.setEditorProgram(player, program)
	end
end

-- Find the workbench Part (tagged Station, attribute Station = "workbench").
local function findWorkbenchPart()
	for _, part in ipairs(CollectionService:GetTagged("Station")) do
		if part:GetAttribute("Station") == "workbench" and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local Players = game:GetService("Players")

Players.PlayerRemoving:Connect(function(player: Player)
	sessionPrograms[player] = nil
end)

function BrainEditorService.init(): ()
	local bench = findWorkbenchPart()
	if bench == nil then
		warn("[scrapcraft] BrainEditorService: no workbench part found — editor prompt disabled")
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Build a Brain"
	prompt.ObjectText = "Brain Workbench"
	prompt.KeyboardKeyCode = Enum.KeyCode.B
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 10
	prompt.Parent = bench

	prompt.Triggered:Connect(function(player: Player)
		Net.remote("Brain"):FireClient(player, {
			type = "open",
			program = BrainEditorService.getEditorProgram(player),
		})
	end)

	Net.remote("Brain").OnServerEvent:Connect(function(player: Player, msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg :: any
		if m.type ~= "run" then return end

		-- 1. Validate (whitelist types/prims/sensors, clamp numbers, caps).
		local check = BrainDoc.validate(m.program)
		if not check.ok then
			Net.remote("Brain"):FireClient(player, {
				type = "runResult", ok = false,
				text = "The yard rejects this brain: " .. table.concat(check.errors, "; "),
			})
			return
		end

		-- 2. Economy + run on the yard bot.
		local label = type(m.name) == "string" and m.name:sub(1, 32) or "Custom Brain"
		local ok, err = BotService.attachCustomBrain(player, m.program, label)
		if ok then
			saveEditorProgram(player, m.program)
		end
		Net.remote("Brain"):FireClient(player, {
			type = "runResult", ok = ok,
			text = ok and label or (err or "could not run"),
		})
	end)

	print("[scrapcraft] brain workbench prompt live (key B at the bench)")
end

-- Default program when a player has none saved (editor client also falls
-- back to STARTER_WALL_AVOIDER itself; exposed for tests).
function BrainEditorService.defaultProgram(): any
	return TileProgram.STARTER_WALL_AVOIDER
end

return BrainEditorService
