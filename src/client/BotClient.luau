--!strict
-- BotClient.luau — Phase 1 STUB (bot logic is another pass). Listens on the
-- ScrapcraftBot RemoteEvent for { type = "status", ... } messages and shows a
-- small top-center toast ("Bot: module attached", "Brain loaded: Wall
-- Avoider", ...).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

local BotClient = {}

local player = Players.LocalPlayer

local toastLabel: TextLabel

local function showToast(text: string): ()
	toastLabel.Text = text
	toastLabel.TextTransparency = 0
	toastLabel.TextStrokeTransparency = 0.4

	local tween = TweenService:Create(toastLabel, TweenInfo.new(1.2), { TextTransparency = 1, TextStrokeTransparency = 1 })
	task.delay(2.5, function()
		tween:Play()
	end)
end

function BotClient.init(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "ScrapcraftBotUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	gui.Parent = playerGui

	toastLabel = Instance.new("TextLabel")
	toastLabel.AnchorPoint = Vector2.new(0.5, 0)
	toastLabel.Position = UDim2.new(0.5, 0, 0, 12)
	toastLabel.Size = UDim2.fromOffset(480, 26)
	toastLabel.BackgroundTransparency = 1
	toastLabel.Font = Enum.Font.GothamBold
	toastLabel.TextSize = 16
	toastLabel.TextColor3 = Color3.fromRGB(140, 220, 255)
	toastLabel.TextStrokeTransparency = 1
	toastLabel.TextTransparency = 1
	toastLabel.Text = ""
	toastLabel.Parent = gui

	Net.remote("Bot").OnClientEvent:Connect(function(msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg :: {type: string?, text: string?}
		if m.type == "status" and m.text ~= nil then
			showToast(m.text)
		end
	end)
end

return BotClient
