--!strict
-- InventoryUI.luau — "Scrap Pouch" panel (left column) rebuilt on every
-- ScrapcraftInv message, plus the cycling hint line bottom-right.
-- Also owns the client-side inventory snapshot other UIs (CraftUI) read.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Items = require(Shared:WaitForChild("Items"))

local InventoryUI = {}

local player = Players.LocalPlayer

-- Client cache of the last server inventory broadcast ({[itemId]: count}).
InventoryUI.snapshot = {} :: {[string]: number}

function InventoryUI.countOf(itemId: string): number
	return InventoryUI.snapshot[itemId] or 0
end

local HINTS = {
	"Mine scrap piles for iron",
	"Craft a wrench at the bench (E)",
	"Attach module + Tin Brain to your bot",
	"Watch it roam",
}

local rowsFrame: ScrollingFrame
local emptyLabel: TextLabel

local function rebuildRows(): ()
	for _, child in ipairs(rowsFrame:GetChildren()) do
		if child:IsA("TextLabel") and child ~= emptyLabel then
			child:Destroy()
		end
	end

	-- Stable display order: by item name.
	local ids = {}
	for itemId, count in pairs(InventoryUI.snapshot) do
		if count > 0 then
			table.insert(ids, itemId)
		end
	end
	table.sort(ids, function(a: string, b: string): boolean
		local da, db = Items.get(a), Items.get(b)
		local na = da ~= nil and da.name or a
		local nb = db ~= nil and db.name or b
		return na < nb
	end)

	emptyLabel.Visible = #ids == 0

	for _, itemId in ipairs(ids) do
		local def = Items.get(itemId)
		local icon = def ~= nil and def.icon or ""
		local name = def ~= nil and def.name or itemId
		local row = Instance.new("TextLabel")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -8, 0, 26)
		row.Font = Enum.Font.Gotham
		row.TextSize = 15
		row.TextColor3 = Color3.new(1, 1, 1)
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextTruncate = Enum.TextTruncate.AtEnd
		row.Text = ("%s  %s  x%d"):format(icon, name, InventoryUI.snapshot[itemId])
		row.Parent = rowsFrame
	end

	rowsFrame.CanvasSize = UDim2.fromOffset(0, #ids * 30)
end

function InventoryUI.init(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "ScrapcraftUI"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	-- Left column: Scrap Pouch.
	local panel = Instance.new("Frame")
	panel.Name = "Pouch"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0.015, 0, 0.5, 0)
	panel.Size = UDim2.fromOffset(230, 340)
	panel.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(10, 8)
	title.Size = UDim2.new(1, -20, 0, 26)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 17
	title.TextColor3 = Color3.fromRGB(255, 200, 90)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Scrap Pouch"
	title.Parent = panel

	rowsFrame = Instance.new("ScrollingFrame")
	rowsFrame.Position = UDim2.fromOffset(10, 40)
	rowsFrame.Size = UDim2.new(1, -20, 1, -50)
	rowsFrame.BackgroundTransparency = 1
	rowsFrame.BorderSizePixel = 0
	rowsFrame.ScrollBarThickness = 4
	rowsFrame.CanvasSize = UDim2.fromOffset(0, 0)
	rowsFrame.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = rowsFrame

	emptyLabel = Instance.new("TextLabel")
	emptyLabel.BackgroundTransparency = 1
	emptyLabel.Size = UDim2.new(1, 0, 0, 24)
	emptyLabel.Font = Enum.Font.Gotham
	emptyLabel.TextSize = 14
	emptyLabel.TextColor3 = Color3.fromRGB(140, 140, 140)
	emptyLabel.TextXAlignment = Enum.TextXAlignment.Left
	emptyLabel.Text = "— empty — go hit a pile"
	emptyLabel.Parent = rowsFrame

	-- Hint line, bottom-right, cycling.
	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(1, 1)
	hint.Position = UDim2.new(1, -16, 1, -12)
	hint.Size = UDim2.fromOffset(420, 22)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 14
	hint.TextColor3 = Color3.fromRGB(200, 200, 200)
	hint.TextStrokeTransparency = 0.6
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.Text = HINTS[1]
	hint.Parent = gui

	-- Server inventory broadcasts → rebuild the pouch.
	Net.remote("Inv").OnClientEvent:Connect(function(msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg :: {type: string?, items: {[string]: number}?}
		if m.type == "inv" and m.items ~= nil then
			InventoryUI.snapshot = m.items
			rebuildRows()
		end
	end)

	rebuildRows()

	-- Cycle the hint strings (not a hot path — a slow loop is fine here).
	task.spawn(function()
		local i = 1
		while true do
			task.wait(7)
			i = (i % #HINTS) + 1
			hint.Text = HINTS[i]
		end
	end)
end

return InventoryUI
