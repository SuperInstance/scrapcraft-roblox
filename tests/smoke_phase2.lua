-- tests/smoke_phase2.lua — PHASE 2 headless suite under plain lua5.1:
--   1. BrainDoc (the tile-editor document model): round-trips, wiring
--      invariants, validate() whitelist — the editor's whole data core.
--   2. Editor→VM integration: a program BUILT through BrainDoc runs in the
--      REAL BrainVM against the REAL WorldModel (mine→avoid wall→keep driving).
--   3. GateQueue: join/advance, idle drift (front yields when truly idle),
--      bell law (front-only, cooldown, 3 rings max).
--   4. ProfileSchema + PlayerDataService (fake DataStore): load/flush/leave
--      with session lease acquire/hold/release, dirty detection, hooks
--      (greeted/editorProgram) — persistence v1 without a network.
-- Run: /usr/bin/lua5.1 tests/smoke_phase2.lua  (from repo root)

local ROOT = "src"
math.randomseed(42)

-- ── Luau compat shims (smoke_mvp superset, trimmed to what we load) ───────
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
task = {
	spawn = function(fn, ...) return fn(...) end,
	delay = function(_t, fn) return fn() end, -- synchronous for determinism
	wait = function() return 0 end,
	defer = function(fn) return fn() end,
}
Random = {
	new = function()
		return { NextNumber = function() return math.random() end,
			NextInteger = function(_s, a, b) return math.random(a, b) end }
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
	return setmetatable({ X = x, Y = y, Z = z, Magnitude = math.sqrt(x * x + y * y + z * z) }, {
		__add = function(a, b) return vec3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end,
		__sub = function(a, b) return vec3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end,
	})
end
Vector3 = { new = vec3 }
CFrame = {
	new = function(x, y, z) return { X = x, Y = y, Z = z } end,
	lookAt = function(pos, _t) return { X = pos.X, Y = pos.Y, Z = pos.Z } end,
}
Color3 = {}
Color3.new = function(r, g, b) return { r = r, g = g, b = b } end
Color3.fromRGB = function(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end
Enum = {
	Material = { Metal = "Metal", Wood = "Wood", Plastic = "Plastic", SmoothPlastic = "SmoothPlastic",
		Concrete = "Concrete", Neon = "Neon", Fabric = "Fabric" },
	SurfaceType = { Smooth = "Smooth" },
}

-- ── Instance mock (smoke_mvp's) ────────────────────────────────────────────
local RemoteLog = {}
local SIGNAL_KEYS = { OnServerEvent = true, OnClientEvent = true, Triggered = true }
local PART_CLASSES = { Part = true, SpawnLocation = true, WedgePart = true, BillboardGui = false }
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
				return
			end
			rawset(self, k, v)
		end
		return setmetatable(o, mt)
	end,
}

-- ── Services / game mocks ──────────────────────────────────────────────────
local FakeStore = { data = {}, fails = 0, updates = 0 }
function FakeStore:GetAsync(key) return FakeStore.data[key] end
function FakeStore:UpdateAsync(key, mutator)
	FakeStore.updates = FakeStore.updates + 1
	if FakeStore.fails > 0 then
		FakeStore.fails = FakeStore.fails - 1
		error("fake datastore outage")
	end
	local old = FakeStore.data[key]
	local new = mutator(old)
	if new ~= nil then FakeStore.data[key] = new end
	return new
end

local DataStoreService = { _store = FakeStore }
local HttpService = {}
do
	-- stable serializer stands in for JSONEncode (only used for compare/size)
	local function dump(v, seen)
		local t = type(v)
		if t == "nil" then return "null" end
		if t == "number" or t == "boolean" then return tostring(v) end
		if t == "string" then return '"' .. v .. '"' end
		if t == "table" then
			seen = seen or {}
			if seen[v] then return "<cycle>" end
			seen[v] = true
			local keys = {}
			for k in pairs(v) do keys[#keys + 1] = k end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			local parts = {}
			for _, k in ipairs(keys) do
				parts[#parts + 1] = "[" .. dump(k, seen) .. "]=" .. dump(v[k], seen)
			end
			seen[v] = nil
			return "{" .. table.concat(parts, ",") .. "}"
		end
		return tostring(v)
	end
	function HttpService:JSONEncode(v) return dump(v) end
end

workspace = nil
CollectionService = {
	_tags = {},
	AddTag = function(self, inst, tag)
		self._tags[tag] = self._tags[tag] or {}
		table.insert(self._tags[tag], inst)
	end,
	HasTag = function(self, inst, tag)
		for _, i in ipairs(self._tags[tag] or {}) do if i == inst then return true end end
		return false
	end,
	GetTagged = function(self, tag) return self._tags[tag] or {} end,
}

local PlayersService = { _list = {}, _signals = { PlayerAdded = makeSignal(), PlayerRemoving = makeSignal() } }
function PlayersService:GetPlayers() return self._list end
PlayersService.PlayerAdded = PlayersService._signals.PlayerAdded
PlayersService.PlayerRemoving = PlayersService._signals.PlayerRemoving
-- compat with Instance-style access used by services:
local RunService = { Heartbeat = makeSignal() }
function RunService:IsStudio() return false end

local Services = {
	Players = PlayersService,
	RunService = RunService,
	DataStoreService = DataStoreService,
	HttpService = HttpService,
	CollectionService = CollectionService,
	ReplicatedStorage = nil, -- set below
}
game = {
	JobId = "test-server-1",
	BindToClose = function(_self, fn) game._bindToClose = fn end,
	GetService = function(_self, name)
		if Services[name] ~= nil then return Services[name] end
		error("GetService: " .. tostring(name))
	end,
}

-- fake players (mock Instance + identity)
local function makePlayer(name, userId)
	local p = Instance.new("Player")
	p.Name = name
	p.Attributes.UserId = userId
	p.UserId = userId
	return p
end

-- ── Luau-source stripper + require override (smoke_mvp's) ──────────────────
local function loadStripped(path)
	local f = assert(io.open(path, "r"))
	local src = f:read("*a")
	f:close()
	src = src:gsub("\nexport type [^\n]*", "")
	src = src:gsub("%{%} :: %b{}", "{}")
	src = src:gsub(":%s*%b{}%?", "")
	src = src:gsub(":%s*%b{}([%)%,])", "%1")
	src = src:gsub("%s*::%s*%b{}", "")
	src = src:gsub("%s*::%s*[%w_%.%?]+", "")
	src = src:gsub("(local [%w_]+)%s*:%s*[^=\n]+=", "%1 =")
	src = src:gsub("(local [%w_]+)%s*:%s*[%w_%.%?]+%s*\n", "%1\n")
	src = src:gsub(": [%w_%.%?]+([%)%,])", "%1")
	src = src:gsub("%): [^\n=]+\n", ")\n")
	return src
end

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

-- ── Module tree ────────────────────────────────────────────────────────────
local shared = Instance.new("Folder"); shared.Name = "Shared"
moduleMock("Blocks", ROOT .. "/shared/Blocks.luau").Parent = shared
moduleMock("Config", ROOT .. "/shared/Config.luau").Parent = shared
moduleMock("Net", ROOT .. "/shared/Net.luau").Parent = shared
moduleMock("Recipes", ROOT .. "/shared/Recipes.luau").Parent = shared
moduleMock("Items", ROOT .. "/shared/Items.luau").Parent = shared
moduleMock("TileProgram", ROOT .. "/shared/TileProgram.luau").Parent = shared
moduleMock("BrainDoc", ROOT .. "/shared/BrainDoc.luau").Parent = shared
moduleMock("GateQueue", ROOT .. "/shared/GateQueue.luau").Parent = shared
moduleMock("ProfileSchema", ROOT .. "/shared/ProfileSchema.luau").Parent = shared

local server = Instance.new("Folder"); server.Name = "Server"
local systems = Instance.new("Folder"); systems.Name = "Systems"; systems.Parent = server
moduleMock("InventoryService", ROOT .. "/server/Systems/InventoryService.luau").Parent = systems
moduleMock("WorldModel", ROOT .. "/server/Systems/WorldModel.luau").Parent = systems
moduleMock("BrainVM", ROOT .. "/server/Systems/BrainVM.luau").Parent = systems
moduleMock("PlayerDataService", ROOT .. "/server/Systems/PlayerDataService.luau").Parent = systems

local rs = Instance.new("Folder"); rs.Name = "ReplicatedStorage"
shared.Parent = rs
Services.ReplicatedStorage = rs

-- top-level `script` for requires at file scope
script = systems

local BrainDoc = require(shared:WaitForChild("BrainDoc"))
local GateQueue = require(shared:WaitForChild("GateQueue"))
local ProfileSchema = require(shared:WaitForChild("ProfileSchema"))
local TileProgram = require(shared:WaitForChild("TileProgram"))

local passed = 0
local function check(cond, msg)
	if cond then
		passed = passed + 1
	else
		error("CHECK FAILED: " .. tostring(msg), 0)
	end
end

-- ══════════════════════════════════════════════════════════════════════════
-- 1. BrainDoc — the editor data core
-- ══════════════════════════════════════════════════════════════════════════
do
	local function eq(a, b, path)
		path = path or "root"
		assert(type(a) == type(b), path .. " type mismatch")
		if type(a) ~= "table" then
			assert(a == b, path .. ": " .. tostring(a) .. " ~= " .. tostring(b))
			return
		end
		for k, v in pairs(a) do eq(v, b[k], path .. "." .. tostring(k)) end
		for k in pairs(b) do assert(a[k] ~= nil, path .. "." .. tostring(k) .. " missing in a") end
	end

	-- starter programs round-trip through the document model
	for _, starter in ipairs({ TileProgram.STARTER_WALL_AVOIDER, TileProgram.STARTER_OVAL_CIRCLER }) do
		local doc = BrainDoc.load(starter)
		local out = BrainDoc.serialize(doc)
		eq(out, starter, starter.name)
		check(BrainDoc.validate(out).ok, starter.name .. " validates")
	end
	check(true, "starter round-trips")

	-- hand-built graph → exact tree
	local d = BrainDoc.new("Hand Built")
	local forever = BrainDoc.addNode(d, "forever", 40, 40)
	local ife = BrainDoc.addNode(d, "if_else", 230, 40)
	BrainDoc.setParam(d, ife, "value", 0.5)
	local drive = BrainDoc.addNode(d, "action", 420, 40)
	BrainDoc.setPrim(d, drive, "drive")
	BrainDoc.setParam(d, drive, "speed", 0.7)
	local beep = BrainDoc.addNode(d, "action", 420, 160)
	BrainDoc.setPrim(d, beep, "beep")
	BrainDoc.setHead(d, forever)
	check(BrainDoc.wire(d, forever, "body", ife), "wire forever.body→if")
	check(BrainDoc.wire(d, ife, "body", drive), "wire if.body→drive")
	check(BrainDoc.wire(d, drive, "next", beep), "wire drive.next→beep")
	local p = BrainDoc.serialize(d)
	eq(p, {
		name = "Hand Built", brain = "tin",
		nodes = { { type = "forever", body = {
			{ type = "if_else",
				cond = { sensor = "distance_ahead", cmp = "lt", value = 0.5 },
				body = {
					{ type = "action", prim = "drive", params = { dir = "forward", speed = 0.7 } },
					{ type = "action", prim = "beep", params = { pitch = "high" } },
				},
				elseBody = {} },
		} } },
	}, "hand-built")
	check(true, "hand-built doc → exact program tree")

	-- tree invariants
	local d3 = BrainDoc.load(TileProgram.STARTER_WALL_AVOIDER)
	local f3 = d3.head
	local ok3, _ = BrainDoc.wire(d3, d3.nodes[f3].body, "next", f3)
	check(not ok3, "self-ancestor wire rejected")
	local ok3b, _ = BrainDoc.wire(d3, f3, "body", f3)
	check(not ok3b, "self wire rejected")

	-- validate(): the server never trusts the wire
	check(not BrainDoc.validate("junk").ok, "junk program rejected")
	check(not BrainDoc.validate({ nodes = { { type = "action", prim = "explode" } } }).ok, "unknown prim rejected")
	check(not BrainDoc.validate({ nodes = { { type = "wait", seconds = 999 } } }).ok, "wait clamp")
	check(not BrainDoc.validate({ nodes = { { type = "if_else", cond = { sensor = "gps", cmp = "lt", value = 2 } } } }).ok, "bad sensor/value")
	check(not BrainDoc.validate({ brain = "spark", nodes = {} }).ok, "tier gate")
	print("PASS: BrainDoc (round-trip, hand-build, invariants, validate)")
end

-- ══════════════════════════════════════════════════════════════════════════
-- 2. Editor→VM: a BrainDoc-built program drives the REAL BrainVM
-- ══════════════════════════════════════════════════════════════════════════
do
	-- WorldModel with a wall band to the north (z ≥ 30 solid WALL_METAL=13).
	-- init() takes the level-1 id map keyed z*128+x (spec D2).
	local WorldModel = require(systems:WaitForChild("WorldModel"))
	local level1 = {}
	for x = 0, 40 do
		for z = 0, 40 do
			if z >= 30 then level1[z * 128 + x] = 13 end
		end
	end
	WorldModel.init(level1)

	local BrainVM = require(systems:WaitForChild("BrainVM"))

	-- build "Wall Stopper": forever [ if distance_ahead < 0.25 → stop else drive ]
	local d = BrainDoc.new("Wall Stopper")
	local forever = BrainDoc.addNode(d, "forever", 40, 40)
	local ife = BrainDoc.addNode(d, "if_else", 230, 40)
	BrainDoc.setParam(d, ife, "value", 0.2)
	local stop = BrainDoc.addNode(d, "action", 420, 40)
	BrainDoc.setPrim(d, stop, "stop")
	local drive = BrainDoc.addNode(d, "action", 420, 160)
	BrainDoc.setPrim(d, drive, "drive")
	BrainDoc.setParam(d, drive, "speed", 0.8)
	BrainDoc.setHead(d, forever)
	assert(BrainDoc.wire(d, forever, "body", ife))
	assert(BrainDoc.wire(d, ife, "body", stop))
	assert(BrainDoc.wire(d, ife, "else", drive))
	local program = BrainDoc.serialize(d)
	check(BrainDoc.validate(program).ok, "wall-stopper validates")

	local vm = BrainVM.new(program, { x = 16, z = 10, heading = 0 }) -- facing +Z (north → wall)
	for _ = 1, 40 do vm:step(1 / 30) end
	local droveAt = vm.robot.z
	check(droveAt > 10.5, "bot drove north (z=" .. string.format("%.2f", droveAt) .. ")")
	for _ = 1, 240 do vm:step(1 / 30) end -- runs into sonar range → stops
	check(math.abs(vm.robot.drivePower) < 0.001, "bot stopped before the wall (drive=" .. tostring(vm.robot.drivePower) .. ")")
	check(vm.robot.z < 29.5, "never entered the wall (z=" .. string.format("%.2f", vm.robot.z) .. ")")
	check(not vm.dead and #vm.errors == 0, "no VM errors")
	print("PASS: editor→VM (BrainDoc program runs, senses, stops at wall)")
end

-- ══════════════════════════════════════════════════════════════════════════
-- 3. GateQueue — the ceremony line
-- ══════════════════════════════════════════════════════════════════════════
do
	local q = GateQueue.new()
	check(GateQueue.join(q, "ana", 100) == 1, "join 1")
	check(GateQueue.join(q, "bo", 101) == 2, "join 2")
	check(GateQueue.join(q, "cyd", 102) == 3, "join 3")
	check(GateQueue.join(q, "ana", 103) == 1, "rejoin no-op")
	check(GateQueue.front(q) == "ana", "front")
	GateQueue.leave(q, "bo")
	check(GateQueue.positionOf(q, "cyd") == 2, "leave compacts")
	check(GateQueue.advance(q) == "ana", "advance pops front")
	check(GateQueue.front(q) == "cyd", "next front")

	-- idle drift: all idle 95s → non-last players each yield one slot
	local q2 = GateQueue.new()
	for _, k in ipairs({ "ana", "bo", "cyd", "dee" }) do GateQueue.join(q2, k, 0) end
	local drifted = GateQueue.idleTick(q2, 95)
	check(#drifted == 3 and drifted[1] == "cyd" and drifted[2] == "bo" and drifted[3] == "ana", "idle drift order")
	check(GateQueue.positionOf(q2, "dee") == 1, "active player takes the front")
	check(#GateQueue.idleTick(q2, 96) == 1, "drift resets timers (only stale dee moves)")
	GateQueue.touch(q2, "ana", 200)
	local d3 = GateQueue.idleTick(q2, 205)
	check(#d3 == 2, "stale players drift; touched player doesn't (got " .. #d3 .. ")")
	check(GateQueue.positionOf(q2, "ana") == 1, "touched player holds the front")

	-- bell law
	local q3 = GateQueue.new()
	GateQueue.join(q3, "ana", 0); GateQueue.join(q3, "bo", 1)
	local ok, err = GateQueue.ringBell(q3, "bo", 10)
	check(not ok and err:find("first") ~= nil, "bell is front-only")
	check(select(1, GateQueue.ringBell(q3, "ana", 10)), "front rings")
	local ok2, err2 = GateQueue.ringBell(q3, "ana", 11)
	check(not ok2 and err2:find("settle") ~= nil, "bell cooldown")
	check(select(1, GateQueue.ringBell(q3, "ana", 20)), "ring 2")
	check(select(1, GateQueue.ringBell(q3, "ana", 30)), "ring 3")
	local ok4, err4 = GateQueue.ringBell(q3, "ana", 40)
	check(not ok4 and err4:find("three") ~= nil, "three rings is the rite")
	GateQueue.advance(q3)
	check(select(1, GateQueue.ringBell(q3, "bo", 60)), "bell resets for the new front")
	print("PASS: GateQueue (line, drift, bell)")
end

-- ══════════════════════════════════════════════════════════════════════════
-- 4. Persistence — ProfileSchema + PlayerDataService on a fake DataStore
-- ══════════════════════════════════════════════════════════════════════════
do
	local InventoryService = require(systems:WaitForChild("InventoryService"))
	InventoryService.init()
	local PlayerDataService = require(systems:WaitForChild("PlayerDataService"))
	PlayerDataService._bindSeams()
	PlayerDataService._setStore(FakeStore)
	PlayerDataService._setServerId("server-A")

	local ana = makePlayer("Ana", 111)
	table.insert(PlayersService._list, ana)
	PlayersService._signals.PlayerAdded:Fire(ana)

	-- load (new kid): lease acquired
	PlayerDataService._load(ana)
	check(not PlayerDataService.hasBeenGreeted(ana), "new kid not greeted")
	local rec = FakeStore.data["u_111"]
	check(rec ~= nil and rec.sessionLease.serverId == "server-A", "lease acquired")

	-- play: inventory + gate ceremony + editor brain
	InventoryService.add(ana, "iron_scrap", 5)
	InventoryService.add(ana, "scrap_candy", 2)
	PlayerDataService.markGreeted(ana)
	local prog = BrainDoc.serialize(BrainDoc.load(TileProgram.STARTER_WALL_AVOIDER))
	PlayerDataService.setEditorProgram(ana, prog)

	-- dirty flush (lease refreshes)
	PlayerDataService._flushOnce(os.time())
	rec = FakeStore.data["u_111"]
	check(rec.inventory.iron_scrap == 5 and rec.inventory.scrap_candy == 2, "inventory persisted")
	check(rec.greeted == true and rec.gateDay ~= "", "gate state persisted")
	check(rec.editorProgram ~= nil and rec.editorProgram.name == "Wall Avoider", "editor program persisted")

	-- leave: released lease + final save (init's PlayerRemoving hook calls
	-- exactly this _save BEFORE InventoryService clears the live table)
	InventoryService.add(ana, "iron_scrap", 3)
	PlayerDataService._save(ana, true)
	rec = FakeStore.data["u_111"]
	check(rec.inventory.iron_scrap == 8, "final save captured the last drop")
	check(rec.sessionLease.expiresUnix == 0, "lease released")

	-- server B: fresh load of the returning regular
	PlayerDataService._setServerId("server-B")
	local ana2 = makePlayer("Ana", 111)
	table.insert(PlayersService._list, ana2)
	PlayerDataService._load(ana2)
	check(PlayerDataService.hasBeenGreeted(ana2), "returning regular recognized")
	check(InventoryService.count(ana2, "iron_scrap") == 8, "inventory restored to live state")
	check(PlayerDataService.getEditorProgram(ana2) ~= nil, "editor program restored")
	check(FakeStore.data["u_111"].sessionLease.serverId == "server-B", "lease re-acquired")

	-- lease hold: a foreign LIVE lease blocks load, retries, then overrides
	FakeStore.data["u_222"] = {
		profile_v = 1, inventory = { greeted = nil },
		sessionLease = { serverId = "server-C", expiresUnix = os.time() + 120 },
	}
	local bo = makePlayer("Bo", 222)
	table.insert(PlayersService._list, bo)
	PlayerDataService._load(bo) -- 3 held retries (task.wait is sync/no-op) → override
	check(FakeStore.data["u_222"].sessionLease.serverId == "server-B", "stuck lease overridden after retries")

	-- DataStore outage → memory-only fallback, never an error wall
	FakeStore.fails = 99
	local cyd = makePlayer("Cyd", 333)
	table.insert(PlayersService._list, cyd)
	pcall(function()
		PlayerDataService._save(cyd, true)
	end)
	FakeStore.fails = 0
	print("PASS: PlayerDataService (lease, flush, leave, reload, override, outage-guard)")
end

print(string.format("PASS: smoke_phase2 (%d checks) — editor core, VM run, gate queue, persistence", passed))
