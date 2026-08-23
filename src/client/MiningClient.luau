--!strict
-- MiningClient.luau — client side of hold-to-mine. Port of the input half of
-- Game.js _updateMine (L1156–1184): every RenderStepped, camera raycast for a
-- Mineable target; while E is held on the same part, progress += dt / hardness
-- (hardness read from the part's BlockId attribute, NOT from the server).
-- The server validates reach + hold time and decides the outcome (see
-- MiningService.luau); replies arrive as { type = "mined", ... } toasts.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = require(Shared:WaitForChild("Config"))
local Blocks = require(Shared:WaitForChild("Blocks"))
local Items = require(Shared:WaitForChild("Items"))

local MiningClient = {}

local player = Players.LocalPlayer

-- ── state ───────────────────────────────────────────────────────────────────
local minePart: BasePart? = nil
local progress = 0
local cooldown = 0 -- brief lockout after firing finish (server destroy latency)

local highlight: Highlight? = nil

-- ── UI ──────────────────────────────────────────────────────────────────────
local holdLabel: TextLabel
local barContainer: Frame
local barFill: Frame
local toastFrame: Frame

local function clamp01(v: number): number
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

local function buildUI(): ()
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "ScrapcraftMining"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = playerGui

	holdLabel = Instance.new("TextLabel")
	holdLabel.Name = "HoldLabel"
	holdLabel.AnchorPoint = Vector2.new(0.5, 1)
	holdLabel.Position = UDim2.new(0.5, 0, 1, -110)
	holdLabel.Size = UDim2.fromOffset(400, 28)
	holdLabel.BackgroundTransparency = 1
	holdLabel.Font = Enum.Font.GothamBold
	holdLabel.TextSize = 18
	holdLabel.TextColor3 = Color3.new(1, 1, 1)
	holdLabel.TextStrokeTransparency = 0.4
	holdLabel.Text = ""
	holdLabel.Visible = false
	holdLabel.Parent = gui

	barContainer = Instance.new("Frame")
	barContainer.Name = "MineBar"
	barContainer.AnchorPoint = Vector2.new(0.5, 1)
	barContainer.Position = UDim2.new(0.5, 0, 1, -80)
	barContainer.Size = UDim2.fromOffset(220, 12)
	barContainer.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	barContainer.BackgroundTransparency = 0.25
	barContainer.BorderSizePixel = 0
	barContainer.Visible = false
	barContainer.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = barContainer

	barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = Color3.fromRGB(255, 170, 40)
	barFill.BorderSizePixel = 0
	barFill.Parent = barContainer

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = barFill

	toastFrame = Instance.new("Frame")
	toastFrame.Name = "Drops"
	toastFrame.AnchorPoint = Vector2.new(1, 0.5)
	toastFrame.Position = UDim2.new(1, -16, 0.5, 0)
	toastFrame.Size = UDim2.fromOffset(260, 300)
	toastFrame.BackgroundTransparency = 1
	toastFrame.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = toastFrame
end

-- Floating drop toast list (+ N Item), with fade-out.
local function toast(text: string, color: Color3): ()
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 24)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.5
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.Text = text
	label.Parent = toastFrame

	task.delay(1.6, function()
		local tween = TweenService:Create(label, TweenInfo.new(1), { TextTransparency = 1, TextStrokeTransparency = 1 })
		tween:Play()
		tween.Completed:Once(function()
			label:Destroy()
		end)
	end)
end

local function itemName(itemId: string): (string, string)
	local def = Items.get(itemId)
	if def ~= nil then
		return def.icon, def.name
	end
	return "", itemId
end

local function onMined(msg: {id: number?, drops: {{itemId: string, qty: number}}?, lucky: string?}): ()
	local drops = msg.drops or {}
	for _, drop in ipairs(drops) do
		local icon, name = itemName(drop.itemId)
		toast(("+ %d %s %s"):format(drop.qty, icon, name), Color3.new(1, 1, 1))
	end
	if msg.lucky ~= nil then
		local icon, name = itemName(msg.lucky)
		toast(("🍀 Lucky Find! %s %s"):format(icon, name), Color3.fromRGB(140, 255, 140))
	end
end

-- ── per-frame targeting ─────────────────────────────────────────────────────

local function setHighlight(part: BasePart?): ()
	if part == nil then
		if highlight ~= nil then
			highlight.Enabled = false
		end
		return
	end
	-- Singleton highlight, parented to the hit part. If the previous parent
	-- was destroyed (mined), the Highlight died with it — recreate.
	if highlight == nil or highlight.Parent == nil then
		highlight = Instance.new("Highlight")
		highlight.FillColor = Color3.fromRGB(255, 170, 40)
		highlight.FillTransparency = 0.6
		highlight.OutlineColor = Color3.new(1, 1, 1)
	end
	highlight.Parent = part
	highlight.Enabled = true
end

function MiningClient.init(): ()
	buildUI()

	local folder = workspace:WaitForChild("Scrapcraft")
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { folder }

	Net.remote("Mine").OnClientEvent:Connect(function(msg: unknown)
		if typeof(msg) == "table" then
			local m = msg :: {type: string?}
			if m.type == "mined" then
				onMined(msg :: {id: number?, drops: {{itemId: string, qty: number}}?, lucky: string?})
			end
		end
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		cooldown = math.max(0, cooldown - dt)

		-- Camera raycast, 256 studs, into the yard folder only.
		local camera = workspace.CurrentCamera
		local target: BasePart? = nil
		if camera ~= nil then
			local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * 256, rayParams)
			if result ~= nil and CollectionService:HasTag(result.Instance, "Mineable") then
				target = result.Instance
			end
		end

		setHighlight(target)

		-- Reach gate for the label + hold loop.
		local inReach = false
		if target ~= nil then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root ~= nil and root:IsA("BasePart") then
				inReach = (root.Position - target.Position).Magnitude <= Config.MINE_REACH_STUDS
			end
		end

		local blockId = tonumber(target ~= nil and target:GetAttribute("BlockId") or nil)
		local def = blockId ~= nil and Blocks.DEF[blockId] or nil
		local label = ""
		if target ~= nil and inReach and def ~= nil then
			label = "Hold E — " .. def.name
		end
		holdLabel.Visible = label ~= ""
		holdLabel.Text = label

		-- Hold-to-mine state machine (client half of Game.js L1156–1184).
		local holding = UserInputService:IsKeyDown(Enum.KeyCode.E)
			and inReach
			and target ~= nil
			and cooldown == 0

		if holding then
			local heldPart = target :: BasePart
			if minePart ~= heldPart then
				-- Target changed → reset progress (Game.js L1165–1168).
				minePart = heldPart
				progress = 0
				Net.remote("Mine"):FireServer({ type = "begin", part = heldPart })
			end
			-- Game.js L1170–1171: hardness fallback 0.5, progress += dt/hardness.
			local hardness = (def ~= nil and def.hardness ~= nil) and def.hardness or 0.5
			progress = progress + dt / hardness
			if progress >= 1 then
				Net.remote("Mine"):FireServer({ type = "finish", part = heldPart })
				minePart = nil
				progress = 0
				cooldown = 0.2
			end
		else
			minePart = nil
			progress = 0
		end

		barContainer.Visible = minePart ~= nil
		barFill.Size = UDim2.fromScale(clamp01(progress), 1)
	end)
end

return MiningClient
