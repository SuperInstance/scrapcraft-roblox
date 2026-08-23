--!strict
-- init.server.luau — server bootstrap.
-- Pass 2: worldgen (YardBuilder) + the bot physics oracle (WorldModel).

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local YardBuilder = require(script.Parent:WaitForChild("WorldGen"):WaitForChild("YardBuilder"))
local WorldModel = require(script.Parent:WaitForChild("Systems"):WaitForChild("WorldModel"))

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

-- TODO Pass 3: MiningService — Net.remote("Mine"), hold-to-mine with
--   Blocks.DEF hardness, drops into InventoryService, WorldModel.removeBlock.
-- TODO Pass 3/4: BotService — spawn chassis at WorldModel.getSpawn(), brains
--   via BrainVM, sonar via WorldModel.distanceAhead.
-- TODO Pass 4: DayNightService.init() + InventoryService/CraftingService wiring.
