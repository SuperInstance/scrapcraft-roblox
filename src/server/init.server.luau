--!strict
-- init.server.luau — server bootstrap.
-- Pass 2: worldgen (YardBuilder) + the bot physics oracle (WorldModel).
-- Pass 3/4: the full MVP service stack — mine → inventory → craft →
-- attach → starter brain → the bot moves (and avoids walls).

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local YardBuilder = require(script.Parent:WaitForChild("WorldGen"):WaitForChild("YardBuilder"))
local WorldModel = require(script.Parent:WaitForChild("Systems"):WaitForChild("WorldModel"))

local InventoryService = require(script.Parent.Systems:WaitForChild("InventoryService"))
local DayNightService = require(script.Parent.Systems:WaitForChild("DayNightService"))
local MiningService = require(script.Parent.Systems:WaitForChild("MiningService"))
local CraftingService = require(script.Parent.Systems:WaitForChild("CraftingService"))
local BotService = require(script.Parent.Systems:WaitForChild("BotService"))

-- The Rojo project file already declares Workspace.Scrapcraft; create if missing.
local folder = Workspace:FindFirstChild("Scrapcraft")
if folder == nil then
	folder = Instance.new("Folder")
	folder.Name = "Scrapcraft"
	folder.Parent = Workspace
end

local result = YardBuilder.generate(folder, Config.SEED)
WorldModel.init(result.level1)

local wb = result.landmarks.workbench
print(string.format("[scrapcraft] yard generated: %d parts, workbench @ %d,%d",
	result.partCount, wb.x, wb.z))

-- Service init order: inventories first (PlayerAdded hooks), day/night
-- before mining (isNight feeds lucky-find odds), then the interactive
-- loop, and the bot last (needs the world + InventoryService).
InventoryService.init()
DayNightService.init()
MiningService.init()
CraftingService.init()
BotService.init(WorldModel, result.landmarks)

print("[scrapcraft] MVP services up")
