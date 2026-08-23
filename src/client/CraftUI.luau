--!strict
-- CraftUI.luau — craft menu. Opens on ScrapcraftCraft { type = "open",
-- station, recipes }; lists recipes with ingredients + craftable state from
-- the client's cached inventory snapshot (InventoryUI). Click row → fire the
-- craft request; on "crafted" stay open and refresh; ESC / X closes.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Items = require(Shared:WaitForChild("Items"))

local InventoryUI = require(script.Parent.InventoryUI)

local CraftUI = {}

local player = Players.LocalPlayer

local gui: ScreenGui
local listFrame: ScrollingFrame
local footer: TextLabel
local stationTitle: TextLabel

-- Recipes currently on offer (from the last "open" message).
local currentRecipes: {any} = {}

local function itemName(itemId: string): string
	local def = Items.get(itemId)
	if def ~= nil then
		local icon = def.icon
		return ("%s %s"):format(icon, def.name)
	end
	return itemId
end

-- "2x Iron Scrap, 1x Wood Plank" — stable order (sorted).
local function ingredientString(recipe: any): string
	local parts = {}
	for itemId, qty in pairs(recipe.ingredients) do
		table.insert(parts, ("%dx %s"):format(qty, itemName(itemId)))
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function isCraftable(recipe: any): boolean
	if recipe.tool ~= nil and InventoryUI.countOf(recipe.tool) < 1 then
		return false
	end
	for itemId, qty in pairs(recipe.ingredients) do
		if InventoryUI.countOf(itemId) < qty then
			return false
		end
	end
	return true
end

local function rebuild(): ()
	for _, child in ipairs(listFrame:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	for i, recipe in ipairs(currentRecipes) do
		local craftable = isCraftable(recipe)
		local qtyText = recipe.qty > 1 and (" x%d"):format(recipe.qty) or ""

		local row = Instance.new("TextButton")
		row.Name = tostring(recipe.id)
		row.AutoButtonColor = craftable
		row.Size = UDim2.new(1, -8, 0, 52)
		row.BackgroundColor3 = craftable and Color3.fromRGB(40, 46, 40) or Color3.fromRGB(34, 34, 36)
		row.BackgroundTransparency = 0.25
		row.BorderSizePixel = 0
		row.Text = ""
		row.LayoutOrder = i
		row.Parent = listFrame

		local nameLine = Instance.new("TextLabel")
		nameLine.BackgroundTransparency = 1
		nameLine.Position = UDim2.fromOffset(10, 4)
		nameLine.Size = UDim2.new(1, -20, 0, 22)
		nameLine.Font = Enum.Font.GothamBold
		nameLine.TextSize = 16
		nameLine.TextColor3 = craftable and Color3.new(1, 1, 1) or Color3.fromRGB(120, 120, 120)
		nameLine.TextXAlignment = Enum.TextXAlignment.Left
		nameLine.TextTruncate = Enum.TextTruncate.AtEnd
		nameLine.Text = itemName(recipe.output) .. qtyText
		nameLine.Parent = row

		local ingLine = Instance.new("TextLabel")
		ingLine.BackgroundTransparency = 1
		ingLine.Position = UDim2.fromOffset(10, 26)
		ingLine.Size = UDim2.new(1, -20, 0, 20)
		ingLine.Font = Enum.Font.Gotham
		ingLine.TextSize = 13
		ingLine.TextColor3 = craftable and Color3.fromRGB(190, 190, 190) or Color3.fromRGB(110, 110, 110)
		ingLine.TextXAlignment = Enum.TextXAlignment.Left
		ingLine.TextTruncate = Enum.TextTruncate.AtEnd
		ingLine.Text = ingredientString(recipe)
		ingLine.Parent = row

		if craftable then
			row.Activated:Connect(function()
				Net.remote("Craft"):FireServer({ type = "craft", recipeId = recipe.id })
			end)
		end
	end

	listFrame.CanvasSize = UDim2.fromOffset(0, #currentRecipes * 58)
end

local function close(): ()
	gui.Enabled = false
end

local function open(station: string, recipes: {any}): ()
	stationTitle.Text = "Craft — " .. station
	currentRecipes = recipes
	footer.Text = ""
	rebuild()
	gui.Enabled = true
end

function CraftUI.init(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "ScrapcraftCraftUI"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 10
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Menu"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(460, 420)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	frame.Parent = gui

	stationTitle = Instance.new("TextLabel")
	stationTitle.BackgroundTransparency = 1
	stationTitle.Position = UDim2.fromOffset(14, 10)
	stationTitle.Size = UDim2.new(1, -60, 0, 26)
	stationTitle.Font = Enum.Font.GothamBold
	stationTitle.TextSize = 18
	stationTitle.TextColor3 = Color3.fromRGB(255, 200, 90)
	stationTitle.TextXAlignment = Enum.TextXAlignment.Left
	stationTitle.Text = "Craft"
	stationTitle.Parent = frame

	local closeButton = Instance.new("TextButton")
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -8, 0, 8)
	closeButton.Size = UDim2.fromOffset(28, 28)
	closeButton.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
	closeButton.BorderSizePixel = 0
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 14
	closeButton.TextColor3 = Color3.new(1, 1, 1)
	closeButton.Text = "X"
	closeButton.Parent = frame
	closeButton.Activated:Connect(close)

	listFrame = Instance.new("ScrollingFrame")
	listFrame.Position = UDim2.fromOffset(10, 44)
	listFrame.Size = UDim2.new(1, -20, 1, -96)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 4
	listFrame.CanvasSize = UDim2.fromOffset(0, 0)
	listFrame.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = listFrame

	footer = Instance.new("TextLabel")
	footer.AnchorPoint = Vector2.new(0.5, 1)
	footer.Position = UDim2.new(0.5, 0, 1, -8)
	footer.Size = UDim2.new(1, -24, 0, 36)
	footer.BackgroundTransparency = 1
	footer.Font = Enum.Font.Gotham
	footer.TextSize = 13
	footer.TextColor3 = Color3.fromRGB(190, 190, 190)
	footer.TextWrapped = true
	footer.TextXAlignment = Enum.TextXAlignment.Left
	footer.TextYAlignment = Enum.TextYAlignment.Bottom
	footer.Text = ""
	footer.Parent = frame

	-- ESC closes (ignore when Roblox already consumed the input, e.g. typing).
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not gameProcessed and input.KeyCode == Enum.KeyCode.Escape and gui.Enabled then
			close()
		end
	end)

	Net.remote("Craft").OnClientEvent:Connect(function(msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg :: {type: string?, station: string?, recipes: {any}?, output: string?, qty: number?, quip: string?, reason: string?}
		if m.type == "open" and m.station ~= nil and m.recipes ~= nil then
			open(m.station, m.recipes)
		elseif m.type == "crafted" then
			-- Stay open, refresh craftable states; show the quip if any.
			footer.TextColor3 = Color3.fromRGB(190, 190, 190)
			local made = ("%s x%d crafted!"):format(itemName(m.output or "?"), m.qty or 1)
			footer.Text = m.quip ~= nil and (made .. "  «" .. m.quip .. "»") or made
			rebuild()
		elseif m.type == "failed" then
			footer.Text = m.reason or "Can't craft that."
			footer.TextColor3 = Color3.fromRGB(255, 120, 120)
			task.delay(2, function()
				footer.TextColor3 = Color3.fromRGB(190, 190, 190)
			end)
		end
	end)
end

return CraftUI
