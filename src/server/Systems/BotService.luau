--!strict
-- BotService.luau — the Gate Edition yard bot: chassis, attach flow, brain
-- life support, battery. Port sources (docs/SPEC-pass3-brain.md):
--   ScrapBot.js _buildMesh — proportions (1 yard unit = Config.CELL studs)
--   ScrapBot.js L382-403   — battery drain / warn / dead
--   botEditions.js gate    — speedMult 0.8 (FOLLOW MODE ONLY — brain mode is
--                            kinematics.js pure, no mult), batteryDrainMult
--                            1.25, bodyColor 0x8A6A4A
-- Phase 1: ONE shared yard bot per server (per-player bots: Phase 2).

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = require(Shared:WaitForChild("Config"))
local TileProgram = require(Shared:WaitForChild("TileProgram"))

local InventoryService = require(script.Parent.InventoryService)
local BrainVM = require(script.Parent.BrainVM)

local BotService = {}

local EDITION = {
	id = "gate",
	label = "Starter ScrapBot (Gate Edition)",
	speedMult = 0.8,        -- follow mode only (Phase 1 has no follow mode)
	batteryDrainMult = 1.25,
	bodyColor = 0x8A6A4A,   -- rustier, less refined — a yard-gate build
}

local bot = nil -- single yard bot

local lastBeepAt = 0

local function hexColor(hex: number)
	local r = bit32.band(bit32.rshift(hex, 16), 0xff)
	local g = bit32.band(bit32.rshift(hex, 8), 0xff)
	local b = bit32.band(hex, 0xff)
	return Color3.fromRGB(r, g, b)
end

local function status(text: string)
	-- text = BotClient's contract; msg = spec pass-3 field. Same string.
	Net.remote("Bot"):FireAllClients({ type = "status", text = text, msg = text })
end

-- ── Chassis (ScrapBot.js _buildMesh proportions, studs = units × CELL) ─────
-- Root = body part (Anchored); every other part is UNanchored + WeldConstraint
-- to the root so per-tick root.CFrame moves the whole bot. Front = −Z face
-- (CFrame.lookAt with forward (sin h, 0, cos h) shows the face/eyes).

local function makePart(name, sizeX, sizeY, sizeZ, color, material, anchored)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = anchored
	p.CanCollide = false
	p.Size = Vector3.new(sizeX, sizeY, sizeZ)
	p.Color = hexColor(color)
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function weld(part, root)
	local w = Instance.new("WeldConstraint")
	w.Part0 = part
	w.Part1 = root
	w.Parent = part
end

local function buildBot(parent, sx, sz, heading)
	local model = Instance.new("Model")
	model.Name = "ScrapBot"

	local root = makePart("ScrapBotBody", 2.0, 2.2, 1.4, EDITION.bodyColor, Enum.Material.Metal, true)
	root.CFrame = CFrame.new(sx, 3.2, sz) -- body center at 0.8 units = 3.2 studs
	model.PrimaryPart = root

	-- head (0.38 x 0.35 x 0.35 u at y 1.25 u)
	local head = makePart("Head", 1.52, 1.4, 1.4, 0x8A9AAA, Enum.Material.SmoothPlastic, false)
	head.CFrame = CFrame.new(sx, 5.0, sz)
	weld(head, root)

	-- eyes: cyan emissive cubes on the FRONT (−Z) face. Placed in root-local
	-- space (root starts unrotated; welds freeze these offsets, so when the
	-- tick loop rotates the root via lookAt the face leads the bot).
	local eyeL = makePart("EyeL", 0.32, 0.32, 0.08, 0x00FFFF, Enum.Material.Neon, false)
	eyeL.CFrame = CFrame.new(sx - 0.4, 5.12, sz - 0.74)
	weld(eyeL, root)
	local eyeR = makePart("EyeR", 0.32, 0.32, 0.08, 0x00FFFF, Enum.Material.Neon, false)
	eyeR.CFrame = CFrame.new(sx + 0.4, 5.12, sz - 0.74)
	weld(eyeR, root)

	-- antenna (0.04 x 0.2 x 0.04 u at y 1.55 u) + red tip at 1.67 u
	local ant = makePart("Antenna", 0.16, 0.8, 0.16, 0xCCCCCC, Enum.Material.Metal, false)
	ant.CFrame = CFrame.new(sx, 6.2, sz)
	weld(ant, root)
	local tip = makePart("AntennaTip", 0.32, 0.32, 0.32, 0xFF4400, Enum.Material.Neon, false)
	tip.CFrame = CFrame.new(sx, 6.68, sz)
	weld(tip, root)

	-- arms (0.15 x 0.45 x 0.15 u at x ±0.35 u, y 0.72 u)
	local armL = makePart("ArmL", 0.6, 1.8, 0.6, EDITION.bodyColor, Enum.Material.Metal, false)
	armL.CFrame = CFrame.new(sx - 1.4, 2.88, sz)
	weld(armL, root)
	local armR = makePart("ArmR", 0.6, 1.8, 0.6, EDITION.bodyColor, Enum.Material.Metal, false)
	armR.CFrame = CFrame.new(sx + 1.4, 2.88, sz)
	weld(armR, root)

	-- legs (0.16 x 0.35 x 0.16 u at x ±0.15 u, y 0.28 u)
	local legL = makePart("LegL", 0.64, 1.4, 0.64, 0x5A4A38, Enum.Material.Metal, false)
	legL.CFrame = CFrame.new(sx - 0.6, 1.12, sz)
	weld(legL, root)
	local legR = makePart("LegR", 0.64, 1.4, 0.64, 0x5A4A38, Enum.Material.Metal, false)
	legR.CFrame = CFrame.new(sx + 0.6, 1.12, sz)
	weld(legR, root)

	-- glow: cyan PointLight on the head (matches _glowLight 0.8 intensity)
	local light = Instance.new("PointLight")
	light.Color = hexColor(0x00FFFF)
	light.Brightness = 0.8
	light.Range = 8
	light.Parent = head

	-- beep Sound stub: no guessed asset ids — silent until the audio pass.
	local sound = Instance.new("Sound")
	sound.Name = "Beep"
	sound.Parent = head

	-- attach flow prompt (Phase 1 single prompt)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Attach Parts"
	prompt.ObjectText = EDITION.label
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 10
	prompt.Parent = root

	root.Parent = model
	model.Parent = parent
	return model, root, prompt
end

-- ── Attach + brain flow ────────────────────────────────────────────────────

local function onAttach(player: Player)
	if bot == nil then return end
	-- 1. Module first (spec order). Phase 1: ultrasonic is the cosmetic
	--    attach step — sensorRangeMult stays 1 (no Wide-Angle Sensors yet).
	if not bot.module and InventoryService.consume(player, "ultrasonic_module", 1) then
		bot.module = true
		bot.model:SetAttribute("Module", "ultrasonic")
		status("📡 Ultrasonic module attached")
		return
	end
	-- 2. Brain.
	if bot.runtime == nil then
		if InventoryService.consume(player, "tin_brain", 1) then
			bot.runtime = BrainVM.new(TileProgram.STARTER_WALL_AVOIDER, {
				x = bot.x, z = bot.z, heading = bot.heading,
			})
			bot.battery = 100
			bot.warned = false
			status("🧠 Brain loaded: Wall Avoider — look at it go")
		elseif bot.module then
			status("Needs a Tin Brain (workbench: 2× circuit board, 4× copper wire, 3× iron scrap)")
		else
			status("Needs an Ultrasonic Module first (workbench), then a Tin Brain")
		end
	else
		status("Brain already running — clear it first to swap")
	end
end

function BotService.clearBrain(reason: string)
	if bot == nil or bot.runtime == nil then return end
	bot.runtime = nil
	status("🛑 Brain stopped: " .. reason)
end

-- ── Phase 2: the tile editor's SAVE & RUN lands here ───────────────────────
-- Same module→brain economy as the prompt flow (module attach, tin_brain
-- consume OR reprogram the running brain). program is ALREADY validated by
-- BrainEditorService (BrainDoc.validate). Returns ok, errText.
function BotService.attachCustomBrain(player: Player, program: any, label: string): (boolean, string?)
	if bot == nil then return false, "no bot in the yard" end
	if not bot.module and not InventoryService.consume(player, "ultrasonic_module", 1) then
		return false, "needs an Ultrasonic Module first (workbench)"
	end
	bot.module = true
	bot.model:SetAttribute("Module", "ultrasonic")
	if bot.runtime == nil then
		if not InventoryService.consume(player, "tin_brain", 1) then
			return false, "needs a Tin Brain (workbench: 2× circuit board, 4× copper wire, 3× iron scrap)"
		end
	end
	bot.runtime = BrainVM.new(program, { x = bot.x, z = bot.z, heading = bot.heading })
	bot.battery = 100
	bot.warned = false
	status("🧠 Brain loaded: " .. label .. " — look at it go")
	return true, nil
end

-- Test/UI introspection.
function BotService.getState()
	if bot == nil then return nil end
	return {
		name = EDITION.label,
		x = bot.x, z = bot.z, heading = bot.heading,
		battery = bot.battery,
		hasBrain = bot.runtime ~= nil,
		hasModule = bot.module,
		errors = bot.runtime ~= nil and #bot.runtime.errors or 0,
		dead = bot.runtime ~= nil and bot.runtime.dead or false,
	}
end

-- ── Tick (RunService.Heartbeat) ────────────────────────────────────────────

local function tick(dt: number)
	if bot == nil or bot.runtime == nil then return end
	local runtime = bot.runtime

	-- Battery (ScrapBot.js): driving = |drivePower| > 0.08; idle 0.4 / drive
	-- 1.3 %/s, × gate batteryDrainMult. Warn once at 15%, dead at 0.
	local driving = math.abs(runtime.robot.drivePower) > 0.08
	local drain = (driving and Config.BATT_DRAIN_DRIVE or Config.BATT_DRAIN_IDLE)
		* EDITION.batteryDrainMult
	bot.battery = math.max(0, bot.battery - drain * dt)
	if bot.battery <= 0 then
		bot.battery = 0
		BotService.clearBrain("🔋 battery depleted — Phase 2: charging pads")
		return
	end
	if bot.battery <= Config.BATT_WARN_PCT and not bot.warned then
		bot.warned = true
		status("🔋 battery critical — 15% remaining!")
	end

	runtime:step(dt)

	bot.x = runtime.robot.x
	bot.z = runtime.robot.z
	bot.heading = runtime.robot.heading

	-- Root pose. cellToStud formula applied to FLOAT positions directly.
	local sx = Config.MAP_ORIGIN + bot.x * Config.CELL + Config.CELL / 2
	local sz = Config.MAP_ORIGIN + bot.z * Config.CELL + Config.CELL / 2
	-- Walk cycle: chose the gentle whole-model bob (±0.15 stud) over leg
	-- swing (spec allows either). Body center rides at 3.2 studs (0.8 u per
	-- the mesh proportions) so the legs stay planted on the ground.
	local bob = driving and math.sin(os.clock() * 12) * 0.15 or 0
	local sy = 3.2 + bob
	bot.root.CFrame = CFrame.lookAt(
		Vector3.new(sx, sy, sz),
		Vector3.new(sx, sy, sz) + Vector3.new(math.sin(bot.heading), 0, math.cos(bot.heading))
	)

	-- Events: beep → throttled status toast (audio pass later; Sound is a
	-- silent stub). led events are cosmetic-only in Phase 1 (skipped).
	for _, ev in ipairs(runtime.robot:drainEvents()) do
		if ev.kind == "beep" and os.clock() - lastBeepAt > 2 then
			lastBeepAt = os.clock()
			status("[BEEP]")
		end
	end
end

-- ── Init ───────────────────────────────────────────────────────────────────

function BotService.init(worldModel, landmarks)
	if bot ~= nil then return end -- one bot per server

	-- Spawn: 2 cells south of the workbench (worldModel.getSpawn is exactly
	-- that — lowest-z bench + 2). If occupied, spec fallback (wb.x+2, wb.z+2).
	local sx, sz = worldModel.getSpawn()
	if worldModel.isSolidAt(sx, sz) then
		local wb = landmarks.workbench
		if wb ~= nil then
			sx, sz = wb.x + 2, wb.z + 2
		end
	end

	local folder = Workspace:FindFirstChild("Scrapcraft")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "Scrapcraft"
		folder.Parent = Workspace
	end

	bot = {
		x = sx, z = sz,
		heading = math.pi, -- facing the bench (heading 0 = +Z; bench is −Z)
		runtime = nil,
		battery = 100,
		module = false,
		warned = false,
		model = nil, root = nil, prompt = nil,
	}
	local model, root, prompt = buildBot(folder,
		Config.MAP_ORIGIN + sx * Config.CELL + Config.CELL / 2,
		Config.MAP_ORIGIN + sz * Config.CELL + Config.CELL / 2,
		bot.heading)
	bot.model = model
	bot.root = root
	bot.prompt = prompt
	model:SetAttribute("Edition", EDITION.id)

	prompt.Triggered:Connect(onAttach)

	-- Client stop button (stub ok, spec): { type = "clear" } stops the brain.
	Net.remote("Bot").OnServerEvent:Connect(function(_player: Player, msg: unknown)
		if typeof(msg) ~= "table" then return end
		local m = msg
		if m.type == "clear" then
			BotService.clearBrain("stopped by player")
		end
	end)

	RunService.Heartbeat:Connect(tick)

	status("🤖 " .. EDITION.label .. " waits by the bench — it needs a module and a brain")
end

return BotService
