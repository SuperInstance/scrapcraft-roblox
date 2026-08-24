--!strict
-- GateClient.luau — Phase 2 client half of Earl's gate: the dialogue panel
-- (Earl's portrait, typewriter text, the answer buttons), the queue chip
-- ("⛑️ #3 in line"), Earl's speech bubble above the man himself, and small
-- ceremony beats (bell 🔔, candy 🍬). Purely a view — the server owns state.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

local GateClient = {}

local player = Players.LocalPlayer

local gui: ScreenGui
local dialogue: Frame
local earlText: TextLabel
local answerRow: Frame
local queueChip: TextLabel
local bubble: BillboardGui
local bubbleText: TextLabel
local typing = false

-- ── Typewriter (Earl speaks at a mechanic's pace) ──────────────────────────

local typeToken = 0

local function typewrite(text: string)
	typeToken = typeToken + 1
	local myToken = typeToken
	typing = true
	earlText.Text = ""
	local delayPer = math.max(0.012, 0.045 - #text * 0.0004)
	for i = 1, #text do
		if typeToken ~= myToken then return end
		earlText.Text = text:sub(1, i)
		task.wait(delayPer)
	end
	if typeToken == myToken then
		earlText.Text = text
		typing = false
	end
end

local function flash(label: TextLabel, text: string)
	label.Text = text
	label.TextTransparency = 0
	local tween = TweenService:Create(label, TweenInfo.new(1.4), { TextTransparency = 1 })
	task.delay(2.2, function() tween:Play() end)
end

-- ── Earl bubble (found by name in Workspace.Scrapcraft.Earl → Head) ────────

local function ensureBubble()
	if bubble ~= nil then return bubble end
	local scrap = Workspace:FindFirstChild("Scrapcraft")
	local earl = scrap ~= nil and scrap:FindFirstChild("Earl") or nil
	local head = earl ~= nil and earl:FindFirstChild("Head") or nil
	if head == nil or not head:IsA("BasePart") then return nil end
	bubble = Instance.new("BillboardGui")
	bubble.Name = "EarlSpeech"
	bubble.Adornee = head
	bubble.Size = UDim2.fromOffset(340, 90)
	bubble.StudsOffset = Vector3.new(0, 3.4, 0)
	bubble.MaxDistance = 80
	bubble.Enabled = false
	bubbleText = Instance.new("TextLabel")
	bubbleText.Size = UDim2.fromScale(1, 1)
	bubbleText.BackgroundTransparency = 1
	bubbleText.Font = Enum.Font.Gotham
	bubbleText.TextSize = 15
	bubbleText.TextWrapped = true
	bubbleText.TextColor3 = Color3.fromRGB(240, 230, 210)
	bubbleText.TextStrokeTransparency = 0.5
	bubbleText.Text = ""
	bubbleText.Parent = bubble
	bubble.Parent = head
	return bubble
end

local bubbleToken = 0

local function showBubble(text: string)
	local b = ensureBubble()
	if b == nil then return end
	bubbleToken = bubbleToken + 1
	local myToken = bubbleToken
	b.Enabled = true
	bubbleText.Text = text
	bubbleText.TextTransparency = 0
	task.delay(6.5, function()
		if bubbleToken == myToken then
			b.Enabled = false
		end
	end)
end

-- ── Dialogue panel ─────────────────────────────────────────────────────────

local function setAnswersVisible(visible: boolean)
	answerRow.Visible = visible
end

local function showEarlLine(text: string, forYou: boolean)
	showBubble(text)
	if forYou then
		dialogue.Visible = true
		setAnswersVisible(false)
		task.spawn(typewrite, text)
	end
end

local function hideDialogue()
	dialogue.Visible = false
	setAnswersVisible(false)
	typeToken = typeToken + 1 -- cut the typewriter
end

-- ── Build ──────────────────────────────────────────────────────────────────

local function mkLabel(parent: Instance, props: {[string]: any}): TextLabel
	local l = Instance.new("TextLabel")
	for k, v in pairs(props) do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

function GateClient.init(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "ScrapcraftGateUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 8
	gui.Parent = playerGui

	-- Queue chip, top-left.
	queueChip = mkLabel(gui, {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 16, 0, 70),
		Size = UDim2.fromOffset(280, 26),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(255, 220, 90),
		TextStrokeTransparency = 0.5,
		Text = "",
	})

	-- Dialogue panel, bottom-center.
	dialogue = Instance.new("Frame")
	dialogue.Name = "EarlDialogue"
	dialogue.AnchorPoint = Vector2.new(0.5, 1)
	dialogue.Position = UDim2.new(0.5, 0, 1, -24)
	dialogue.Size = UDim2.fromOffset(560, 150)
	dialogue.BackgroundColor3 = Color3.fromRGB(28, 30, 34)
	dialogue.BackgroundTransparency = 0.05
	dialogue.BorderSizePixel = 0
	dialogue.Visible = false
	dialogue.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = dialogue

	mkLabel(dialogue, {
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.fromOffset(200, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(230, 200, 140),
		Text = "🧔 EARL — yard boss",
	})

	earlText = mkLabel(dialogue, {
		Position = UDim2.fromOffset(16, 36),
		Size = UDim2.new(1, -32, 0, 66),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 16,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Color3.fromRGB(235, 235, 235),
		Text = "",
	})

	-- Answer buttons (server sends {type="answer"} when it's time).
	answerRow = Instance.new("Frame")
	answerRow.Name = "Answers"
	answerRow.Position = UDim2.new(0, 16, 1, -44)
	answerRow.Size = UDim2.new(1, -32, 0, 34)
	answerRow.BackgroundTransparency = 1
	answerRow.Visible = false
	answerRow.Parent = dialogue

	local function mkAnswer(x: number, w: number, label: string, choice: string, accent: Color3)
		local b = Instance.new("TextButton")
		b.Position = UDim2.fromOffset(x, 0)
		b.Size = UDim2.fromOffset(w, 34)
		b.BackgroundColor3 = accent
		b.BackgroundTransparency = 0.15
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.TextColor3 = Color3.fromRGB(235, 235, 235)
		b.Text = label
		b.Parent = answerRow
		local ac = Instance.new("UICorner")
		ac.CornerRadius = UDim.new(0, 8)
		ac.Parent = b
		b.Activated:Connect(function()
			setAnswersVisible(false)
			Net.remote("Gate"):FireServer({ type = "answer", choice = choice })
		end)
	end
	mkAnswer(0, 250, "⛏️ \"I can dig.\"", "dig", Color3.fromRGB(60, 110, 70))
	mkAnswer(262, 250, "🛢️ \"…what's the blue drum?\"", "drum", Color3.fromRGB(60, 76, 110))

	-- Toast line (bell / candy beats) reuses the chip row.
	local toast = mkLabel(gui, {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 16, 0, 96),
		Size = UDim2.fromOffset(340, 24),
		Font = Enum.Font.Gotham,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(180, 230, 180),
		TextStrokeTransparency = 0.5,
		TextTransparency = 1,
		Text = "",
	})

	Net.remote("Gate").OnClientEvent:Connect(function(msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg :: any
		if m.type == "earl" and type(m.text) == "string" then
			showEarlLine(m.text, m.forYou == true)
		elseif m.type == "queue" then
			local pos, total = tonumber(m.position) or 0, tonumber(m.total) or 0
			if pos == 0 then
				queueChip.Text = ""
			elseif pos == 1 then
				queueChip.Text = ("⛏️ You're FIRST — %d behind you"):format(total - 1)
			else
				queueChip.Text = ("⛑️ #%d in line — %d ahead"):format(pos, pos - 1)
			end
		elseif m.type == "answer" then
			setAnswersVisible(true)
		elseif m.type == "open" then
			hideDialogue()
			queueChip.Text = ""
			flash(toast, "🚪 The gate clacks open. You're in.")
		elseif m.type == "bell" then
			flash(toast, "🔔🔔🔔")
		elseif m.type == "candy" then
			flash(toast, "🍬 Earl lobs you a scrap candy")
		elseif m.type == "drift" then
			flash(toast, "…you drifted back a spot. The gate is patient.")
		end
	end)

	print("[scrapcraft] gate client up")
end

return GateClient
