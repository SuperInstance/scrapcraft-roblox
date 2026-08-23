-- tests/smoke_mvp.lua — END-TO-END MVP loop under plain lua5.1 with a stubbed
-- Roblox API, driving the REAL service modules:
--   mine (level-1 + THE LEVEL>=2 DESTROY FIX) -> inventory -> craft (tool
--   gates, all-or-nothing) -> attach module/brain -> starter brain -> bot
--   moves + avoids walls + battery drains -> clear -> battery death.
-- Plus BrainVM unit checks (clamp, wrap, wait/halt, unknown-prim) and the
-- DayNight cycle. Run: /usr/bin/lua5.1 tests/smoke_mvp.lua  (from repo root)

local ROOT = "src"
math.randomseed(42) -- deterministic drop rolls (Random shim below)

-- ── Luau compat shims ──────────────────────────────────────────────────────
math.round = math.round or function(x) return math.floor(x + 0.5) end
bit32 = {
	band = function(a, b)
		local res, bit = 0, 1
		while a > 0 and b > 0 do
			if a % 2 == 1 and b % 2 == 1 then res = res + bit end
			a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
		end
		return res
	end,
	rshift = function(a, n) return math.floor(a / 2 ^ n) end,
}
typeof = function(v)
	if type(v) == "table" and rawget(v, "ClassName") ~= nil then return "Instance" end
	return type(v)
end
Random = {
	new = function()
		return {
			NextNumber = function() return math.random() end,
			NextInteger = function(_self, a, b) return math.random(a, b) end,
		}
	end,
}

-- ── Signals / value mocks ──────────────────────────────────────────────────
local function makeSignal()
	local s = { _fns = {} }
	function s:Connect(fn) table.insert(self._fns, fn); return { Connected = true } end
	function s:Fire(...) for _, fn in ipairs(self._fns) do fn(...) end end
	return s
end

local function vec3(x, y, z)
	local v = { X = x, Y = y, Z = z, Magnitude = math.sqrt(x * x + y * y + z * z) }
	return setmetatable(v, {
		__add = function(a, b) return vec3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end,
		__sub = function(a, b) return vec3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end,
	})
end
Vector3 = { new = vec3 }
CFrame = {
	new = function(x, y, z) return { X = x, Y = y, Z = z } end,
	lookAt = function(pos, target) return { X = pos.X, Y = pos.Y, Z = pos.Z, Look = target } end,
}
Color3 = {}
Color3.new = function(r, g, b)
	return { r = r, g = g, b = b, Lerp = function(self, other, a)
		return Color3.new(self.r + (other.r - self.r) * a, self.g + (other.g - self.g) * a, self.b + (other.b - self.b) * a)
	end }
end
Color3.fromRGB = function(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end
Enum = {
	Material = { Metal = "Metal", Wood = "Wood", Plastic = "Plastic", SmoothPlastic = "SmoothPlastic",
		Concrete = "Concrete", Neon = "Neon" },
	SurfaceType = { Smooth = "Smooth" },
}

-- ── Instance mock (superset of smoke_pass2's) ─────────────────────────────
local RemoteLog = {}
local SIGNAL_KEYS = {
	OnServerEvent = true, OnClientEvent = true, Triggered = true,
}
local PART_CLASSES = { Part = true, SpawnLocation = true, WedgePart = true }
local METHODS = {
	WaitForChild = function(self, n)
		for _, c in ipairs(self.Children) do if c.Name == n then return c end end
		error("WaitForChild: no child named " .. tostring(n))
	end,
	FindFirstChild = function(self, n)
		for _, c in ipairs(self.Children) do if c.Name == n then return c end end
		return nil
	end,
	FindFirstChildOfClass = function(self, cls)
		for _, c in ipairs(self.Children) do if c.ClassName == cls then return c end end
		return nil
	end,
	GetChildren = function(self) return self.Children end,
	IsA = function(self, cls)
		if cls == "Instance" then return true end
		if cls == "BasePart" then return PART_CLASSES[self.ClassName] == true end
		return self.ClassName == cls
	end,
	GetAttribute = function(self, k) return self.Attributes[k] end,
	SetAttribute = function(self, k, v) self.Attributes[k] = v end,
	Destroy = function(self)
		self.Destroyed = true
		self.Parent = nil
	end,
	FireClient = function(self, player, msg)
		table.insert(RemoteLog, { remote = self.Name, player = player, msg = msg })
	end,
	FireAllClients = function(self, msg)
		table.insert(RemoteLog, { remote = self.Name, player = nil, msg = msg })
	end,
}
Instance = {
	new = function(className)
		local o = { ClassName = className, Name = "", Children = {}, Attributes = {} }
		local mt = {}
		mt.__index = function(self, k)
			local v = rawget(self, k)
			if v ~= nil then return v end
			if METHODS[k] ~= nil then return METHODS[k] end
			if k == "Position" then
				local cf = rawget(self, "CFrame")
				if cf ~= nil then return vec3(cf.X, cf.Y, cf.Z) end
				return nil
			end
			if SIGNAL_KEYS[k] then
				local s = makeSignal()
				rawset(self, k, s)
				return s
			end
			-- child access by dot (script.Parent.WorldModel in the services)
			for _, c in ipairs(self.Children) do if c.Name == k then return c end end
			return nil
		end
		mt.__newindex = function(self, k, v)
			if k == "Parent" then
				local old = rawget(self, "Parent")
				if old ~= nil then
					for i, c in ipairs(old.Children) do
						if c == self then table.remove(old.Children, i) break end
					end
				end
				rawset(self, k, v)
				if v ~= nil then table.insert(v.Children, self) end
			else
				rawset(self, k, v)
			end
		end
		return setmetatable(o, mt)
	end,
}

-- ── Service mocks ──────────────────────────────────────────────────────────
local CollectionService = { _tags = {}, _added = {} }
function CollectionService:AddTag(inst, tag)
	local list = self._tags[tag]
	if list == nil then list = {}; self._tags[tag] = list end
	table.insert(list, inst)
	local sig = self._added[tag]
	if sig ~= nil then sig:Fire(inst) end
end
function CollectionService:HasTag(inst, tag)
	for _, i in ipairs(self._tags[tag] or {}) do if i == inst then return true end end
	return false
end
function CollectionService:GetTagged(tag) return self._tags[tag] or {} end
function CollectionService:GetInstanceAddedSignal(tag)
	local sig = self._added[tag]
	if sig == nil then sig = makeSignal(); self._added[tag] = sig end
	return sig
end

local Players = { PlayerAdded = makeSignal(), PlayerRemoving = makeSignal(), _list = {} }
function Players:GetPlayers() return self._list end

local RunService = { Heartbeat = makeSignal() }
local Lighting = Instance.new("Lighting")

local rs = Instance.new("Folder"); rs.Name = "ReplicatedStorage"
local WorkspaceService = Instance.new("Folder"); WorkspaceService.Name = "Workspace"

game = {
	GetService = function(_self, name)
		if name == "CollectionService" then return CollectionService end
		if name == "ReplicatedStorage" then return rs end
		if name == "Players" then return Players end
		if name == "RunService" then return RunService end
		if name == "Lighting" then return Lighting end
		if name == "Workspace" then return WorkspaceService end
		error("GetService: " .. name)
	end,
}

-- ── Luau-source stripper (superset of smoke_pass2's) ───────────────────────
local function loadStripped(path)
	local f = assert(io.open(path, "r"))
	local src = f:read("*a")
	f:close()
	src = src:gsub("\nexport type [^\n]*", "")
	src = src:gsub("%{%} :: %b{}", "{}")
	src = src:gsub(":%s*%b{}%?", "")          -- optional table-typed param
	src = src:gsub(":%s*%b{}([%)%,])", "%1")  -- table-typed param
	src = src:gsub("%s*::%s*%b{}", "")        -- cast to table type
	src = src:gsub("%s*::%s*[%w_%.%?]+", "")  -- cast to simple name
	src = src:gsub("(local [%w_]+)%s*:%s*[^=\n]+=", "%1 =") -- typed local, w/ init
	src = src:gsub("(local [%w_]+)%s*:%s*[%w_%.]+%s*\n", "%1\n") -- typed local
	src = src:gsub(": [%w_%.]+([%)%,])", "%1")  -- param annotations
	src = src:gsub("%): [^\n=]+\n", ")\n")      -- return annotations
	return src
end

-- ── require override ───────────────────────────────────────────────────────
local moduleCache = {}
function require(mock)
	local path = mock._modulePath
	if moduleCache[path] then return moduleCache[path] end
	local chunk = assert(loadstring(loadStripped(path), path))
	local prevScript = script
	script = mock
	local m = chunk()
	script = prevScript
	moduleCache[path] = m
	return m
end

local function moduleMock(name, path)
	local m = Instance.new("ModuleScript")
	m.Name = name
	m._modulePath = path
	return m
end

local function folder(name)
	local f = Instance.new("Folder")
	f.Name = name
	return f
end

-- ── Service tree ───────────────────────────────────────────────────────────
local shared = folder("Shared")
moduleMock("Blocks", ROOT .. "/shared/Blocks.luau").Parent = shared
moduleMock("Config", ROOT .. "/shared/Config.luau").Parent = shared
moduleMock("Net", ROOT .. "/shared/Net.luau").Parent = shared
moduleMock("Recipes", ROOT .. "/shared/Recipes.luau").Parent = shared
moduleMock("TileProgram", ROOT .. "/shared/TileProgram.luau").Parent = shared
shared.Parent = rs

local worldGen = folder("WorldGen")
moduleMock("LCG", ROOT .. "/server/WorldGen/LCG.luau").Parent = worldGen
moduleMock("YardBuilder", ROOT .. "/server/WorldGen/YardBuilder.luau").Parent = worldGen
local systems = folder("Systems")
moduleMock("WorldModel", ROOT .. "/server/Systems/WorldModel.luau").Parent = systems
moduleMock("DayNightService", ROOT .. "/server/Systems/DayNightService.luau").Parent = systems
moduleMock("InventoryService", ROOT .. "/server/Systems/InventoryService.luau").Parent = systems
moduleMock("MiningService", ROOT .. "/server/Systems/MiningService.luau").Parent = systems
moduleMock("CraftingService", ROOT .. "/server/Systems/CraftingService.luau").Parent = systems
moduleMock("BrainVM", ROOT .. "/server/Systems/BrainVM.luau").Parent = systems
moduleMock("BotService", ROOT .. "/server/Systems/BotService.luau").Parent = systems
local server = folder("Server")
worldGen.Parent = server
systems.Parent = server

-- ── Boot the stack exactly like init.server.luau ───────────────────────────
local YardBuilder = require(worldGen:WaitForChild("YardBuilder"))
local WorldModel = require(systems:WaitForChild("WorldModel"))
local Net = require(shared:WaitForChild("Net"))
local Blocks = require(shared:WaitForChild("Blocks"))
local TileProgram = require(shared:WaitForChild("TileProgram"))
local BrainVM = require(systems:WaitForChild("BrainVM"))
local InventoryService = require(systems:WaitForChild("InventoryService"))
local DayNightService = require(systems:WaitForChild("DayNightService"))
local MiningService = require(systems:WaitForChild("MiningService"))
local CraftingService = require(systems:WaitForChild("CraftingService"))
local BotService = require(systems:WaitForChild("BotService"))

local yard = folder("Scrapcraft")
local res = YardBuilder.generate(yard, 42)
WorldModel.init(res.level1)
InventoryService.init()
DayNightService.init()
MiningService.init()
CraftingService.init()

local mineRemote = Net.remote("Mine")
local craftRemote = Net.remote("Craft")
local botRemote = Net.remote("Bot")

-- ── Player ─────────────────────────────────────────────────────────────────
local player, playerRoot
do
	player = Instance.new("Player")
	player.Name = "Tester"
	local char = Instance.new("Model"); char.Name = "Tester"
	playerRoot = Instance.new("Part"); playerRoot.Name = "HumanoidRootPart"
	playerRoot.Parent = char
	player.Character = char
	table.insert(Players._list, player)
	Players.PlayerAdded:Fire(player)
end

local function check(cond, msg)
	if cond then print("ok   " .. msg) else print("FAIL " .. msg); os.exit(1) end
end

local function placeAt(part)
	playerRoot.CFrame = CFrame.new(part.CFrame.X, part.CFrame.Y, part.CFrame.Z)
end

local function beginMine(part)
	mineRemote.OnServerEvent:Fire(player, { type = "begin", part = part })
end

local function finishMine(part)
	mineRemote.OnServerEvent:Fire(player, { type = "finish", part = part })
end

local function holdFor(s)
	local t0 = os.clock()
	while os.clock() - t0 < s do end
end

local function countMined()
	local n = 0
	for _, e in ipairs(RemoteLog) do
		if e.remote == "ScrapcraftMine" and e.player == player and e.msg.type == "mined" then
			n = n + 1
		end
	end
	return n
end

local function lastCraft()
	for i = #RemoteLog, 1, -1 do
		local e = RemoteLog[i]
		if e.remote == "ScrapcraftCraft" and e.player == player then return e.msg end
	end
	return nil
end

local function lastBotStatus()
	for i = #RemoteLog, 1, -1 do
		local e = RemoteLog[i]
		if e.remote == "ScrapcraftBot" and e.msg and e.msg.type == "status" then
			return e.msg.text
		end
	end
	return nil
end

-- ══════════════════════════════════════════════════════════════════════════
print("== 1. Mining: the level>=2 destroy fix + the level-1 path ==")

-- find a stack: same (x,z) cell holding a Mineable level-1 part AND a
-- Mineable level>=2 part (junk cars / oil-drum stacks / scrap clusters)
local byCell = {}
for _, p in ipairs(CollectionService:GetTagged("Block")) do
	if CollectionService:HasTag(p, "Mineable") then
		local k = p:GetAttribute("X") .. "_" .. p:GetAttribute("Z")
		if byCell[k] == nil then byCell[k] = {} end
		table.insert(byCell[k], p)
	end
end
local lv1Part, lv2Part
for _, list in pairs(byCell) do
	local a, b
	for _, p in ipairs(list) do
		local lv = p:GetAttribute("Level")
		if lv == 1 then a = p end
		if lv ~= nil and lv >= 2 then b = p end
	end
	if a ~= nil and b ~= nil then
		local def = Blocks.DEF[b:GetAttribute("BlockId")]
		if def ~= nil and def.hardness ~= nil and def.hardness <= 0.6 then
			lv1Part, lv2Part = a, b
			break
		end
	end
end
check(lv2Part ~= nil, "found a mineable stack (level 1 + level 2) to test the fix")

local cellX, cellZ = lv2Part:GetAttribute("X"), lv2Part:GetAttribute("Z")
local lv2Id = lv2Part:GetAttribute("BlockId")
check(WorldModel.isSolidAt(cellX, cellZ) == true, "stack cell solid via level-1 occupancy before mining")

placeAt(lv2Part)
beginMine(lv2Part)
holdFor(Blocks.DEF[lv2Id].hardness + 0.1)
finishMine(lv2Part)

check(lv2Part.Destroyed == true, "FIX VERIFIED: mining a level>=2 block DESTROYS its part")
check(lv1Part.Destroyed ~= true, "level-1 part underneath untouched")
check(WorldModel.isSolidAt(cellX, cellZ) == true, "level-1 occupancy survives (removeBlock no-ops for level>=2)")
check(countMined() == 1, "mined message fired with drops")

-- now mine the level-1 part of the same cell (WorldModel destroy path)
placeAt(lv1Part)
beginMine(lv1Part)
holdFor(Blocks.DEF[lv1Part:GetAttribute("BlockId")].hardness + 0.1)
finishMine(lv1Part)
check(lv1Part.Destroyed == true, "level-1 mining destroys its part")
check(WorldModel.isSolidAt(cellX, cellZ) == false, "occupancy cleared after level-1 mined")
check(countMined() == 2, "second mined message fired")

-- negatives: too fast, out of reach, non-mineable
local slowPart
for _, p in ipairs(CollectionService:GetTagged("Mineable")) do
	local def = Blocks.DEF[p:GetAttribute("BlockId")]
	if def ~= nil and (def.hardness or 0) >= 0.4 and p.Destroyed ~= true then
		slowPart = p
		break
	end
end
check(slowPart ~= nil, "found a slower block for the hold-time negative")
placeAt(slowPart)
beginMine(slowPart)
finishMine(slowPart) -- immediately: elapsed << hardness * 0.9
check(slowPart.Destroyed ~= true, "too-fast finish rejected (hold-duration gate)")
check(countMined() == 2, "no mined message for the rejected finish")

playerRoot.CFrame = CFrame.new(0, 5, 0) -- far from everything in the yard
beginMine(slowPart)
holdFor(Blocks.DEF[slowPart:GetAttribute("BlockId")].hardness + 0.1)
finishMine(slowPart)
check(slowPart.Destroyed ~= true, "out-of-reach mine rejected")

local benchPart
for _, p in ipairs(CollectionService:GetTagged("Station")) do
	if p:GetAttribute("Station") == "workbench" then benchPart = p break end
end
check(benchPart ~= nil, "found a workbench (non-mineable station)")
placeAt(benchPart)
beginMine(benchPart)
holdFor(1.0)
finishMine(benchPart)
check(benchPart.Destroyed ~= true, "non-mineable station cannot be mined")

print("== 2. Inventory + crafting ==")

-- mining drops above may have seeded the pouch — assert against baselines
local baseIron = InventoryService.count(player, "iron_scrap")
local baseWood = InventoryService.count(player, "wood_plank")
local baseCircuit = InventoryService.count(player, "circuit_board")

InventoryService.add(player, "iron_scrap", 3)
InventoryService.add(player, "wood_plank", 1)
craftRemote.OnServerEvent:Fire(player, { type = "craft", recipeId = "r_wrench" })
check(InventoryService.count(player, "wrench") == 1, "crafted: wrench")
check(InventoryService.count(player, "iron_scrap") == baseIron and InventoryService.count(player, "wood_plank") == baseWood,
	"ingredients consumed all-or-nothing")

-- tool gate BEFORE owning pliers
local cbBefore = InventoryService.count(player, "circuit_board")
InventoryService.add(player, "circuit_board", 2)
InventoryService.add(player, "copper_wire", 4)
InventoryService.add(player, "iron_scrap", 3)
craftRemote.OnServerEvent:Fire(player, { type = "craft", recipeId = "r_tin_brain" })
check(lastCraft().type == "failed" and string.find(lastCraft().reason, "pliers") ~= nil,
	"tool gate: tin brain refused without pliers")
check(InventoryService.count(player, "circuit_board") == cbBefore + 2, "nothing consumed on failure")

InventoryService.add(player, "iron_scrap", 2)
InventoryService.add(player, "copper_wire", 1)
craftRemote.OnServerEvent:Fire(player, { type = "craft", recipeId = "r_pliers" })
check(InventoryService.count(player, "pliers") == 1, "crafted: pliers")

InventoryService.add(player, "circuit_board", 1)
InventoryService.add(player, "copper_wire", 2)
craftRemote.OnServerEvent:Fire(player, { type = "craft", recipeId = "r_ultrasonic_module" })
check(InventoryService.count(player, "ultrasonic_module") == 1, "crafted: ultrasonic module")

-- ingredients for the brain are already in the pouch (added pre-gate test)
craftRemote.OnServerEvent:Fire(player, { type = "craft", recipeId = "r_tin_brain" })
check(InventoryService.count(player, "tin_brain") == 1, "crafted: tin brain (tool gate passed)")

craftRemote.OnServerEvent:Fire(player, { type = "craft", recipeId = "r_nope" })
check(lastCraft().type == "failed" and lastCraft().reason == "Unknown recipe.", "unknown recipe rejected")

-- station prompt opens the menu with its recipe list
local benchPrompt
for _, c in ipairs(benchPart:GetChildren()) do
	if c.ClassName == "ProximityPrompt" then benchPrompt = c end
end
check(benchPrompt ~= nil, "workbench has a Craft prompt")
benchPrompt.Triggered:Fire(player)
local opened
for i = #RemoteLog, 1, -1 do
	local e = RemoteLog[i]
	if e.remote == "ScrapcraftCraft" and e.player == player and e.msg.type == "open" then
		opened = e.msg
		break
	end
end
check(opened ~= nil and #opened.recipes > 0 and opened.station == "workbench",
	"prompt opens craft menu with workbench recipes")

print("== 3. Bot: spawn, attach module + brain ==")

BotService.init(WorldModel, res.landmarks)
local st = BotService.getState()
check(st ~= nil, "yard bot spawned")
check(st.hasBrain == false and st.hasModule == false, "bot starts empty (no module, no brain)")
check(WorldModel.isSolidAt(st.x, st.z) == false, "bot spawn cell is clear")

local botModel = WorkspaceService:FindFirstChild("Scrapcraft"):FindFirstChild("ScrapBot")
check(botModel ~= nil and botModel.PrimaryPart ~= nil, "ScrapBot model built in Workspace")
check(botModel:GetAttribute("Edition") == "gate", "Gate Edition chassis")

local function fireBotPrompt()
	local prompt
	for _, c in ipairs(botModel.PrimaryPart:GetChildren()) do
		if c.ClassName == "ProximityPrompt" then prompt = c end
	end
	prompt.Triggered:Fire(player)
end

-- stash the section-2 crafted module + brain (walkthrough starts empty-handed)
InventoryService.consume(player, "ultrasonic_module", 1)
InventoryService.consume(player, "tin_brain", 1)

fireBotPrompt()
check(string.find(lastBotStatus() or "", "Needs") ~= nil, "attach hint when pouch is empty")

InventoryService.add(player, "ultrasonic_module", 1)
fireBotPrompt()
check(BotService.getState().hasModule == true, "ultrasonic module attached")
check(InventoryService.count(player, "ultrasonic_module") == 0, "module consumed")
check(botModel:GetAttribute("Module") == "ultrasonic", "model tagged Module=ultrasonic")

InventoryService.add(player, "tin_brain", 1)
fireBotPrompt()
st = BotService.getState()
check(st.hasBrain == true and st.errors == 0, "tin brain loaded (Wall Avoider), VM clean")
check(st.battery == 100, "battery starts at 100%")

print("== 4. Brain runs: bot moves, avoids walls, drains battery ==")

local startX, startZ = st.x, st.z
local dt = 1 / 30
local maxDisp, insideSolid, minBatt = 0, false, 100
for _ = 1, 450 do -- 15 s of Heartbeat
	RunService.Heartbeat:Fire(dt)
	local s = BotService.getState()
	local disp = math.sqrt((s.x - startX) ^ 2 + (s.z - startZ) ^ 2)
	if disp > maxDisp then maxDisp = disp end
	if s.battery < minBatt then minBatt = s.battery end
	if WorldModel.isSolidAt(s.x, s.z) then insideSolid = true end
end
local sawBeep = false
for _, e in ipairs(RemoteLog) do
	if e.remote == "ScrapcraftBot" and e.msg and e.msg.text == "[BEEP]" then sawBeep = true break end
end
st = BotService.getState()
check(st.hasBrain == true and st.dead == false and st.errors == 0, "brain ran 15 s with zero VM errors")
check(maxDisp > 1.0, "bot MOVED: max displacement " .. string.format("%.1f", maxDisp) .. " cells from spawn")
check(not insideSolid, "wall avoidance: bot never entered a solid cell")
check(sawBeep, "avoid branch fired ([BEEP] toast seen)")
check(minBatt < 100 and st.battery > 15,
	"battery draining at real rates: " .. string.format("%.0f%% after 15 s (idle 0.4 / drive 1.3 x1.25 gate)", st.battery))

print("== 5. Clear + battery death ==")

botRemote.OnServerEvent:Fire(player, { type = "clear" })
check(BotService.getState().hasBrain == false, "clear stops the brain")
local idleX, idleZ = BotService.getState().x, BotService.getState().z
for _ = 1, 60 do RunService.Heartbeat:Fire(dt) end
check(BotService.getState().x == idleX and BotService.getState().z == idleZ, "bot idles in place after clear")

InventoryService.add(player, "tin_brain", 1)
fireBotPrompt()
check(BotService.getState().hasBrain == true, "second brain loaded")
local simT = 0
while BotService.getState().hasBrain and simT < 200 do
	RunService.Heartbeat:Fire(dt)
	simT = simT + dt
end
check(BotService.getState().hasBrain == false, "battery depletes -> brain auto-cleared (after " .. string.format("%.0f s", simT) .. ")")
check(string.find(lastBotStatus() or "", "battery depleted") ~= nil, "depletion status fired")

print("== 6. BrainVM unit semantics ==")

-- clamp + drive/turn independence + heading wrap
local wrapProg = {
	nodes = {
		{ type = "forever", body = {
			{ type = "action", prim = "turn", params = { dir = "right", speed = 2 } },
		} },
	},
}
local rt = BrainVM.new(wrapProg, { x = 8, z = 5, heading = 0 })
for _ = 1, 105 do rt:step(1 / 30) end -- 3.5 s at clamped power 1 -> 630 deg
check(rt.robot.turnPower == 1, "turn power clamped to [-1, 1]")
check(rt.robot.drivePower == 0, "turn does not touch drivePower (primitives.js)")
check(math.abs(rt.robot.heading) <= math.pi + 1e-9, "heading wrapped to [-pi, pi]")

-- unknown primitive -> error + halt + motors cut
local badProg = { nodes = { { type = "action", prim = "warp" } } }
local rt2 = BrainVM.new(badProg, { x = 8, z = 5, heading = 0 })
rt2.robot:setDrive(0.5)
rt2:step(1 / 30)
check(rt2.dead == true and #rt2.errors == 1, "unknown primitive halts with an error")
check(rt2.robot.drivePower == 0, "halt cuts motors (TileVM HALT safety)")

-- wait keeps motors live; program end halts and cuts them
local waitProg = {
	nodes = {
		{ type = "action", prim = "drive", params = { dir = "forward", speed = 1 } },
		{ type = "wait", seconds = 0.5 },
	},
}
local rt3 = BrainVM.new(waitProg, { x = 8, z = 5, heading = 0 })
for _ = 1, 5 do rt3:step(1 / 30) end -- mid-wait
check(rt3.dead == false and rt3.robot.drivePower == 1, "motors stay set during WAIT")
for _ = 1, 20 do rt3:step(1 / 30) end -- wait expires, program ends
check(rt3.dead == true and rt3.robot.drivePower == 0, "program end halts and cuts motors")

print("== 7. Day/night ==")

local t0 = DayNightService.getT()
for _ = 1, 900 do RunService.Heartbeat:Fire(1 / 30) end -- 30 s
local t1 = DayNightService.getT()
local advanced = (t1 - t0) % 1
check(math.abs(advanced - 30 / 360) < 0.005, "day cycle advanced 30 s worth: " .. string.format("%.4f", advanced))
check(Lighting.ClockTime == t1 * 24, "ClockTime tracks the cycle")

print("PASS: smoke_mvp (mine->inventory->craft->attach->brain->move/avoid, level>=2 fix verified)")
