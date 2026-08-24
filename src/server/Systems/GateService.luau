--!strict
-- GateService.luau — Phase 2: Earl's gate, where the queue IS the ceremony
-- (docs/PHASE2-SHARED-YARD.md §3). Server-authoritative:
--   · first-timers line up south of the gate (GateQueue, max 7 numbered hard
--     hats as billboard GUIs); the front player gets Earl's full greeting;
--   · returning regulars: the gate just clacks open + one gruff-warm line;
--   · the bell (front-of-line only, 3 rings, cooldown), scrap candy lobbed
--     to the waiting line every 8 s, idle drift (never the front);
--   · the doors are real parts — they open on the answer, close behind.
-- Greeted state persists via PlayerDataService when present (session memory
-- otherwise). Earl's lines are canon-verbatim where the doc marks them so.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = require(Shared:WaitForChild("Config"))
local GateQueue = require(Shared:WaitForChild("GateQueue"))

local InventoryService = require(script.Parent.InventoryService)

local GateService = {}

-- ── Geometry (YardBuilder's gate: pylons cells (6,3)/(10,3), road x=8) ────
local GATE_Z_CELL = 3
local PX_A, PX_B = 6, 10 -- pylon cells
local studX = function(cx: number) return Config.MAP_ORIGIN + cx * Config.CELL + Config.CELL / 2 end
local studZ = function(cz: number) return Config.MAP_ORIGIN + cz * Config.CELL + Config.CELL / 2 end
local GATE_X = (studX(PX_A) + studX(PX_B)) / 2 -- road centerline
local GATE_Z = studZ(GATE_Z_CELL)
local STAGE_Z = studZ(0)                        -- first-timer staging row
local GREET_RANGE = 16                          -- studs: front player in range → ceremony
local CROSS_Z = GATE_Z + 6                      -- north of this = through the gate
local CANDY_EVERY = 8
local LINE_SPREAD = 6                           -- studs between queue slots on stage row

-- ── Earl's lines (canon voice sheet: short declaratives, gruff-warm) ───────
local LINES = {
	firstTimer = {
		"So you finally showed up.",
		"The junk's been piling up waiting for someone with thumbs. Name's Earl. I run this place.",
		"Don't touch the blue drum. Just… don't.",
		"Now — see that rust heap? Mine me five iron off it and we'll see what you're made of.",
	},
	drumAnswer = "Don't. Touch. The blue drum. …Kids.",
	digAnswer = "Attaboy. Gate's open — five iron. GO.",
	returning = "Back again, huh. Yard noticed. Gate's open — leave the candy wrapper in the bin this time, genius.",
	toQueue = "Relax, rookies. Yard's been standing since before you were born. It'll hold together another ninety seconds.",
	bell = "…Somebody's eager. Fine. FINE.",
}

-- ── State ──────────────────────────────────────────────────────────────────
local queue = GateQueue.new()
local greeted: {[Player]: boolean} = {}        -- session fallback (profile wins)
local PlayerDataService: any = nil             -- set by setPersistence
local ceremony = { key = nil, phase = "idle", t = 0, beat = 0 }
local doorsOpen = false
local doorL: BasePart, doorR: BasePart
local bellPart: BasePart
local lastCandyAt = 0
local lastQueueToastAt = 0
local returningGreetedAt: {[Player]: number} = {} -- per-regular cooldown (no spam while loitering)
local doorClosedCF: any
local doorOpenCF: any

-- ── Persistence hooks ──────────────────────────────────────────────────────
function GateService.setPersistence(pds: any)
	PlayerDataService = pds
end

local function hasBeenGreeted(player: Player): boolean
	if PlayerDataService ~= nil and PlayerDataService.hasBeenGreeted(player) then
		return true
	end
	return greeted[player] == true
end

local function markGreeted(player: Player)
	greeted[player] = true
	if PlayerDataService ~= nil then
		PlayerDataService.markGreeted(player)
	end
end

-- ── Gate messaging helpers ─────────────────────────────────────────────────

local function toPlayer(player: Player, msg: any)
	Net.remote("Gate"):FireClient(player, msg)
end

local function earlSpeaks(text: string, forPlayer: Player?)
	-- Bubble above Earl for everyone watching + dialogue panel for the kid.
	for _, p in ipairs(Players:GetPlayers()) do
		toPlayer(p, {
			type = "earl", text = text,
			forYou = forPlayer ~= nil and p == forPlayer,
		})
	end
end

local function pushQueueState(player: Player)
	local pos = GateQueue.positionOf(queue, player)
	toPlayer(player, {
		type = "queue",
		position = pos or 0,
		total = #GateQueue.snapshot(queue),
		firstTimer = not hasBeenGreeted(player),
	})
end

local function pushQueueStateAll()
	for _, p in ipairs(Players:GetPlayers()) do
		pushQueueState(p)
	end
end

-- ── Hard hats (numbered billboard over each queued character) ──────────────

local function refreshHardHats()
	local order = GateQueue.snapshot(queue)
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local head = char ~= nil and char:FindFirstChild("Head") or nil
		if head == nil then continue end
		local pos = GateQueue.positionOf(queue, player)
		local hat = head:FindFirstChild("QueueHat")
		if pos == nil or pos > GateQueue.MAX_VISIBLE then
			if hat ~= nil then hat:Destroy() end
			continue
		end
		local gui = hat
		if gui == nil then
			gui = Instance.new("BillboardGui")
			gui.Name = "QueueHat"
			gui.Adornee = head
			gui.Size = UDim2.fromOffset(120, 40)
			gui.StudsOffset = Vector3.new(0, 2.6, 0)
			gui.AlwaysOnTop = true
			gui.MaxDistance = 120
			local label = Instance.new("TextLabel")
			label.Name = "Num"
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundTransparency = 1
			label.Font = Enum.Font.GothamBold
			label.TextSize = 18
			label.TextColor3 = Color3.fromRGB(255, 220, 90)
			label.TextStrokeTransparency = 0.3
			label.Text = ""
			label.Parent = gui
			gui.Parent = head
		end
		local label = gui:FindFirstChild("Num")
		if label ~= nil and label:IsA("TextLabel") then
			label.Text = (pos == 1 and "⛏️ ▶ 1" or "⛑️ " .. pos)
		end
	end
end

-- ── The doors ──────────────────────────────────────────────────────────────

local function buildDoor(cf: CFrame): BasePart
	local door = Instance.new("Part")
	door.Name = "GateDoor"
	door.Size = Vector3.new(6, 12, 0.6)
	door.CFrame = cf
	door.Anchored = true
	door.Material = Enum.Material.Metal
	door.Color = Color3.fromRGB(96, 78, 52) -- weathered wood-steel yard gate
	door.TopSurface = Enum.SurfaceType.Smooth
	door.BottomSurface = Enum.SurfaceType.Smooth
	door.Parent = Workspace:WaitForChild("Scrapcraft")
	return door
end

-- Closed + open CFrame for one door; the open pose pivots 100° about the
-- hinge edge, swinging NORTH into the yard. Left door (hinge west, extends
-- +X): θ=−100° takes +X→+Z. Right door (extends −X): θ=+100° takes −X→+Z.
local function doorCFs(hingeX: number, width: number, extendsPlusX: boolean)
	local h = Vector3.new(hingeX, 6, GATE_Z)
	local half = Vector3.new(extendsPlusX and width / 2 or -width / 2, 0, 0)
	local closed = CFrame.new(h + half)
	local theta = (extendsPlusX and -1 or 1) * math.rad(100)
	local open = CFrame.new(h) * CFrame.Angles(0, theta, 0) * CFrame.new(half)
	return closed, open
end

local function setDoors(open: boolean)
	if doorL == nil or doorR == nil then return end
	if open == doorsOpen then return end
	doorsOpen = open
	local info = TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(doorL, info, { CFrame = open and doorOpenCF.L or doorClosedCF.L }):Play()
	TweenService:Create(doorR, info, { CFrame = open and doorOpenCF.R or doorClosedCF.R }):Play()
end

-- ── Earl (a yard boss built from parts — lanky, flannel, hard hat) ─────────

local function buildEarl(parent: Instance)
	local function part(name: string, size: Vector3, color: Color3, mat: Enum.Material): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = color
		p.Material = mat
		p.Anchored = true
		p.CanCollide = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		return p
	end
	local model = Instance.new("Model")
	model.Name = "Earl"
	local flannel = Color3.fromRGB(122, 62, 52)
	local denim = Color3.fromRGB(58, 70, 92)
	local skin = Color3.fromRGB(214, 168, 138)

	local ex, ez = studX(PX_A) - 6, GATE_Z - 4 -- beside the gate, watching the line

	local torso = part("Torso", Vector3.new(2.2, 2.8, 1.2), flannel, Enum.Material.Fabric)
	torso.CFrame = CFrame.new(ex, 4.4, ez)
	torso.Parent = model

	local legs = part("Legs", Vector3.new(1.9, 3.0, 1.1), denim, Enum.Material.Fabric)
	legs.CFrame = CFrame.new(ex, 1.5, ez)
	legs.Parent = model

	local head = part("Head", Vector3.new(1.4, 1.4, 1.4), skin, Enum.Material.SmoothPlastic)
	head.CFrame = CFrame.new(ex, 6.5, ez)
	head.Parent = model

	local beard = part("Beard", Vector3.new(1.3, 0.7, 0.35), Color3.fromRGB(180, 180, 180), Enum.Material.Fabric)
	beard.CFrame = CFrame.new(ex, 6.1, ez - 0.75)
	beard.Parent = model

	local hat = part("HardHat", Vector3.new(1.7, 0.6, 1.7), Color3.fromRGB(242, 194, 48), Enum.Material.SmoothPlastic)
	hat.CFrame = CFrame.new(ex, 7.5, ez)
	hat.Parent = model

	-- arm gesturing at the rust heap (north into the yard)
	local arm = part("Arm", Vector3.new(0.6, 2.2, 0.6), flannel, Enum.Material.Fabric)
	arm.CFrame = CFrame.new(ex - 1.4, 4.6, ez) * CFrame.Angles(0, 0, math.rad(40))
	arm.Parent = model

	local tag = Instance.new("BillboardGui")
	tag.Name = "EarlTag"
	tag.Adornee = head
	tag.Size = UDim2.fromOffset(160, 30)
	tag.StudsOffset = Vector3.new(0, 1.9, 0)
	tag.MaxDistance = 90
	local tagLabel = Instance.new("TextLabel")
	tagLabel.Size = UDim2.fromScale(1, 1)
	tagLabel.BackgroundTransparency = 1
	tagLabel.Font = Enum.Font.GothamBold
	tagLabel.TextSize = 15
	tagLabel.TextColor3 = Color3.fromRGB(230, 200, 140)
	tagLabel.TextStrokeTransparency = 0.4
	tagLabel.Text = "EARL — yard boss"
	tagLabel.Parent = tag
	tag.Parent = head

	-- The bell, on the west pylon (front-of-line only; enabled in tick)
	bellPart = part("GateBell", Vector3.new(1.0, 1.0, 1.0), Color3.fromRGB(218, 170, 60), Enum.Material.Metal)
	bellPart.CFrame = CFrame.new(studX(PX_A) + 1.4, 10.5, GATE_Z)
	bellPart.Parent = model

	local bellPrompt = Instance.new("ProximityPrompt")
	bellPrompt.ActionText = "Ring the Bell"
	bellPrompt.ObjectText = "gate bell"
	bellPrompt.RequiresLineOfSight = false
	bellPrompt.MaxActivationDistance = 12
	bellPrompt.Parent = bellPart
	bellPrompt.Triggered:Connect(function(player: Player)
		local now = os.clock()
		local ok, err = GateQueue.ringBell(queue, player, now)
		if ok then
			earlSpeaks(LINES.bell, nil)
			for _, p in ipairs(Players:GetPlayers()) do
				toPlayer(p, { type = "bell", rings = GateQueue.BELL_MAX_RINGS })
			end
		elseif err ~= nil and player ~= nil then
			toPlayer(player, { type = "earl", text = "Earl: " .. err, forYou = true })
		end
	end)

	model.PrimaryPart = torso
	model.Parent = parent
	return model
end

-- ── Ceremony state machine (follows queue.front(); front is never drifted) ─

local function startCeremony(key: Player)
	ceremony.key = key
	ceremony.phase = "greet"
	ceremony.t = os.clock() - 5.5 -- first beat lands immediately, ~5.5s apart
	ceremony.beat = 0
end

local function endCeremony(completed: boolean)
	if ceremony.key ~= nil and completed then
		markGreeted(ceremony.key)
		pushQueueState(ceremony.key)
	end
	ceremony.key = nil
	ceremony.phase = "idle"
end

local function ceremonyTick(now: number)
	local front = GateQueue.front(queue)
	if front == nil then
		if ceremony.key ~= nil then endCeremony(false) end
		setDoors(false)
		return
	end
	-- Front changed (drift/leave): reset; the new front starts when in range.
	if ceremony.key ~= front then
		endCeremony(false)
		setDoors(false)
	end

	local char = front.Character
	local root = char ~= nil and char:FindFirstChild("HumanoidRootPart") or nil
	local inRange = root ~= nil and (root.Position - Vector3.new(GATE_X, 0, GATE_Z)).Magnitude < GREET_RANGE

	if ceremony.phase == "idle" then
		if inRange then startCeremony(front) end
		return
	end
	if ceremony.key ~= front then return end

	if ceremony.phase == "greet" then
		local beats = LINES.firstTimer
		local i = ceremony.beat + 1
		-- one beat every ~5.5s, gated by the player's pace (they're listening)
		if now - ceremony.t >= 5.5 and i <= #beats then
			ceremony.beat = i
			ceremony.t = now
			earlSpeaks(beats[i], front)
			if i == #beats then
				ceremony.phase = "answer"
				toPlayer(front, { type = "answer" })
			end
		end
	elseif ceremony.phase == "open" then
		-- wait for the walk-through (their own pace) or 45s patience
		local crossed = root ~= nil and root.Position.Z > CROSS_Z
		if crossed or now - ceremony.t > 45 then
			local key = ceremony.key
			GateQueue.advance(queue)
			endCeremony(true)
			setDoors(false)
			pushQueueStateAll()
			refreshHardHats()
			if key ~= nil then
				toPlayer(key, { type = "open" })
			end
		end
	end
end

-- ── Player lifecycle ───────────────────────────────────────────────────────

local function onCharacter(player: Player, char: Model)
	local root = char:WaitForChild("HumanoidRootPart", 10)
	if root ~= nil and root:IsA("BasePart") then
		if not hasBeenGreeted(player) then
			-- First-timer: stage south of the gate, behind the closed doors.
			-- Slot along the stage row by queue position so the line reads.
			local pos = GateQueue.positionOf(queue, player) or 1
			local slotX = GATE_X + ((pos % 2 == 0) and 1 or -1) * math.ceil(pos / 2) * LINE_SPREAD
			root.CFrame = CFrame.new(slotX, 6, STAGE_Z)
		end
	end
	refreshHardHats()
end

local function onPlayer(player: Player)
	if PlayerDataService ~= nil then
		PlayerDataService.awaitProfile(player, 5) -- regular-vs-rookie never races the load
	end
	if hasBeenGreeted(player) then
		-- Returning regular: no ceremony. The gate clacks open as they pass.
		player.CharacterAdded:Connect(function(char)
			onCharacter(player, char)
		end)
		if player.Character ~= nil then
			onCharacter(player, player.Character)
		end
		pushQueueState(player)
		return
	end
	GateQueue.join(queue, player, os.clock())
	player.CharacterAdded:Connect(function(char)
		onCharacter(player, char)
	end)
	if player.Character ~= nil then
		onCharacter(player, player.Character)
	end
	pushQueueStateAll()
	refreshHardHats()
end

local function onPlayerRemoving(player: Player)
	GateQueue.leave(queue, player)
	greeted[player] = nil
	returningGreetedAt[player] = nil
	if ceremony.key == player then
		endCeremony(false)
		setDoors(false)
	end
	pushQueueStateAll()
	refreshHardHats()
end

-- ── Answer handling ────────────────────────────────────────────────────────

local function onAnswer(player: Player, choice: string)
	if ceremony.key ~= player or ceremony.phase ~= "answer" then return end
	if choice == "drum" then
		earlSpeaks(LINES.drumAnswer, player)
		task.delay(4, function()
			if ceremony.key == player and ceremony.phase == "answer" then
				earlSpeaks(LINES.firstTimer[4], player)
			end
		end)
		return
	end
	earlSpeaks(LINES.digAnswer, player)
	ceremony.phase = "open"
	ceremony.t = os.clock()
	setDoors(true)
end

-- ── Main tick (2 Hz + candy cadence + queue texture) ───────────────────────

local lastTouchSample = 0

local function tick(dt: number)
	local now = os.clock()

	-- Movement sampling → queue touch (pin against idle drift), 1 Hz.
	if now - lastTouchSample >= 1 then
		lastTouchSample = now
		for _, key in ipairs(GateQueue.snapshot(queue)) do
			local char = key.Character
			local root = char ~= nil and char:FindFirstChild("HumanoidRootPart") or nil
			local hum = char ~= nil and char:FindFirstChildOfClass("Humanoid") or nil
			if root ~= nil and root:IsA("BasePart") and hum ~= nil and hum:IsA("Humanoid") then
				local active = hum.MoveDirection.Magnitude > 0.05
					or (ceremony.key == key and ceremony.phase ~= "idle")
				if active then
					GateQueue.touch(queue, key, now)
				end
			end
		end
		local drifted = GateQueue.idleTick(queue, now)
		if #drifted > 0 then
			refreshHardHats()
			pushQueueStateAll()
			for _, key in ipairs(drifted) do
				toPlayer(key, { type = "drift" })
			end
		end
	end

	ceremonyTick(now)

	-- Candy: every 8s to the WAITING line (positions 2..7) while it exists.
	if now - lastCandyAt >= CANDY_EVERY then
		lastCandyAt = now
		local order = GateQueue.snapshot(queue)
		if #order >= 2 then
			for i = 2, math.min(#order, GateQueue.MAX_VISIBLE) do
				local key = order[i]
				InventoryService.add(key, "scrap_candy", 1)
				toPlayer(key, { type = "candy" })
			end
			if now - lastQueueToastAt > 30 then
				lastQueueToastAt = now
				earlSpeaks(LINES.toQueue, nil)
			end
		end
	end

	-- Returning regulars: auto-clack when near the gate (60s per-regular
	-- cooldown so loitering at the arch doesn't put Earl on a loop).
	for _, player in ipairs(Players:GetPlayers()) do
		if hasBeenGreeted(player) and not doorsOpen then
			local char = player.Character
			local root = char ~= nil and char:FindFirstChild("HumanoidRootPart") or nil
			if root ~= nil and root:IsA("BasePart") then
				local d = (root.Position - Vector3.new(GATE_X, 0, GATE_Z)).Magnitude
				local last = returningGreetedAt[player] or 0
				if d < 14 and now - last > 60 then
					returningGreetedAt[player] = now
					setDoors(true)
					toPlayer(player, { type = "earl", text = LINES.returning, forYou = true })
					task.delay(6, function()
						if ceremony.phase == "idle" then setDoors(false) end
					end)
				end
			end
		end
	end
end

-- ── Init ───────────────────────────────────────────────────────────────────

function GateService.init(): ()
	local folder = Workspace:FindFirstChild("Scrapcraft")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "Scrapcraft"
		folder.Parent = Workspace
	end

	-- Doors between the pylons: inner gap is cells 7..9 = 12 studs, 2 panels.
	local gapA = studX(PX_A) + Config.CELL / 2 -- inner face of west pylon
	local gapB = studX(PX_B) - Config.CELL / 2 -- inner face of east pylon
	local w = (gapB - gapA) / 2
	local cL, oL = doorCFs(gapA, w, true)
	local cR, oR = doorCFs(gapB, w, false)
	doorL = buildDoor(cL)
	doorR = buildDoor(cR)
	doorClosedCF = { L = cL, R = cR }
	doorOpenCF = { L = oL, R = oR }

	buildEarl(folder)

	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayer, player)
	end

	Net.remote("Gate").OnServerEvent:Connect(function(player: Player, msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg :: any
		if m.type == "answer" then
			onAnswer(player, tostring(m.choice))
		end
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		tick(dt)
	end)

	print("[scrapcraft] Earl's gate stands — the queue is the ceremony")
end

return GateService
