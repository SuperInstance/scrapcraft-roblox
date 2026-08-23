-- tests/smoke_pass2.lua — runs YardBuilder.generate + WorldModel under plain
-- lua5.1 with a stubbed Roblox API. Verifies: generation completes, part
-- count is self-consistent, determinism (two runs, same layout hash), spawn
-- clearing, landmarks, and WorldModel solidity/sonar/removeBlock.
-- Run: /usr/bin/lua5.1 tests/smoke_pass2.lua   (from repo root)

local ROOT = "src"

-- ── Luau compat shims (5.1 lacks these; parse-safe, runtime-stubbed) ───────
math.round = math.round or function(x) return math.floor(x + 0.5) end
bit32 = bit32 or {
	band = function(a, b) return (a % 256) and 0 or 0 end, -- replaced below
}
-- real bit32 band/rshift via arithmetic (hex colors are 24-bit)
bit32.band = function(a, b)
	local res, bit = 0, 1
	while a > 0 and b > 0 do
		local abit, bbit = a % 2, b % 2
		if abit == 1 and bbit == 1 then res = res + bit end
		a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
	end
	return res
end
bit32.rshift = function(a, n)
	return math.floor(a / 2 ^ n)
end

-- ── Strip Luau-only syntax the shared modules use (type annotations) ───────
local function loadStripped(path)
	local f = assert(io.open(path, "r"))
	local src = f:read("*a")
	f:close()
	src = src:gsub("\nexport type [^\n]*", "")            -- LCG export type line (^ anchors only at string start in Lua patterns)
	src = src:gsub("%{%} :: %b{}", "{}")                 -- LCG setmetatable cast
	src = src:gsub(": [%w_%.]+([%)%,])", "%1")           -- param annotations
	src = src:gsub("%): [^\n=]+\n", ")\n")               -- return annotations
	return src
end

-- ── Instance mock (global: module chunks see globals, not harness locals) ──
Instance = {
	new = function(className)
		local o = { ClassName = className, Name = "", Children = {}, Attributes = {}, Tags = {} }
		local mt = {}
		mt.__index = function(self, k)
			return rawget(self, k) or rawget(getmetatable(self), "methods")[k]
		end
		mt.__newindex = function(self, k, v)
			if k == "Parent" then
				rawset(self, k, v)
				if v ~= nil then table.insert(v.Children, self) end
			else
				rawset(self, k, v)
			end
		end
		mt.methods = {
			WaitForChild = function(self, n)
				for _, c in ipairs(self.Children) do if c.Name == n then return c end end
				error("WaitForChild: no child named " .. n)
			end,
			FindFirstChild = function(self, n)
				for _, c in ipairs(self.Children) do if c.Name == n then return c end end
				return nil
			end,
			SetAttribute = function(self, k, v) self.Attributes[k] = v end,
			GetAttribute = function(self, k) return self.Attributes[k] end,
			Destroy = function(self) self.Destroyed = true end,
		}
		return setmetatable(o, mt)
	end,
}

-- ── CollectionService mock ─────────────────────────────────────────────────
local CollectionService = { _tags = {} }
function CollectionService:AddTag(inst, tag)
	self._tags[tag] = self._tags[tag] or {}
	table.insert(self._tags[tag], inst)
end
function CollectionService:GetTagged(tag)
	return self._tags[tag] or {}
end

-- ── Value-type mocks ───────────────────────────────────────────────────────
Vector3 = { new = function(x, y, z) return { x = x, y = y, z = z } end }
CFrame = { new = function(x, y, z) return { x = x, y = y, z = z } end }
Color3 = {}
Color3.new = function(r, g, b) return { r = r, g = g, b = b, Lerp = function(self, other, a)
	return Color3.new(self.r + (other.r - self.r) * a, self.g + (other.g - self.g) * a, self.b + (other.b - self.b) * a)
end } end
Color3.fromRGB = function(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end
Enum = {
	Material = { Metal = "Metal", Wood = "Wood", Plastic = "Plastic", SmoothPlastic = "SmoothPlastic", Concrete = "Concrete" },
	SurfaceType = { Smooth = "Smooth" },
}

-- ── require override: mock instances carry _modulePath ─────────────────────
local moduleCache = {}
local realRequire = require
function require(mock)
	local path = mock._modulePath
	if moduleCache[path] then return moduleCache[path] end
	local chunk = assert(loadstring(loadStripped(path), path))
	-- in Roblox, `script` inside a ModuleScript is the module itself (per
	-- VM identity, not a true global) — save/restore for nested requires
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

-- ── Service tree mock ──────────────────────────────────────────────────────
local shared = Instance.new("Folder"); shared.Name = "Shared"
moduleMock("Blocks", ROOT .. "/shared/Blocks.luau").Parent = shared
moduleMock("Config", ROOT .. "/shared/Config.luau").Parent = shared
local rs = Instance.new("Folder"); rs.Name = "ReplicatedStorage"
shared.Parent = rs

local worldGen = Instance.new("Folder"); worldGen.Name = "WorldGen"
moduleMock("LCG", ROOT .. "/server/WorldGen/LCG.luau").Parent = worldGen
moduleMock("YardBuilder", ROOT .. "/server/WorldGen/YardBuilder.luau").Parent = worldGen
local systems = Instance.new("Folder"); systems.Name = "Systems"
moduleMock("WorldModel", ROOT .. "/server/Systems/WorldModel.luau").Parent = systems
local server = Instance.new("Folder"); server.Name = "Server"
worldGen.Parent = server; systems.Parent = server

game = {
	GetService = function(self, name)
		if name == "CollectionService" then return CollectionService end
		if name == "ReplicatedStorage" then return rs end
		error("GetService: " .. name)
	end,
}

-- ── Run generation twice; compare layout hashes ────────────────────────────
local YardBuilder = require(worldGen:WaitForChild("YardBuilder"))
local WorldModel = require(systems:WaitForChild("WorldModel"))

local function runOnce()
	local folder = Instance.new("Folder"); folder.Name = "Scrapcraft"
	local res = YardBuilder.generate(folder, 42)
	-- hash the block layout in creation order (y,z,x loops => deterministic)
	local h = 0
	local blocksFolder = folder:FindFirstChild("Blocks")
	local n = 0
	for _, p in ipairs(blocksFolder.Children) do
		local id, x, z, lv = p:GetAttribute("BlockId"), p:GetAttribute("X"), p:GetAttribute("Z"), p:GetAttribute("Level")
		h = (h * 31 + id * 7 + x * 3 + z * 5 + lv) % 2 ^ 31
		n = n + 1
	end
	return res, n, h, folder
end

local res1, blockParts1, hash1 = runOnce()
local res2, blockParts2, hash2 = runOnce()

local function check(cond, msg)
	if cond then print("ok   " .. msg) else print("FAIL " .. msg); os.exit(1) end
end

check(blockParts1 > 0, "block parts created: " .. blockParts1)
check(res1.partCount == blockParts1 + 8, "partCount == block parts + 8 ground parts (" .. res1.partCount .. ")")
check(hash1 == hash2 and blockParts1 == blockParts2, "deterministic: same layout hash on re-run")
check(res1.landmarks.workbench.x == 12 and res1.landmarks.workbench.z == 8, "workbench landmark @ 12,8")
check(res1.level1[8 * 128 + 12] == 8, "level1 grid has WORKBENCH at (12,8)")

-- spawn clearing: no block parts in cells (7..9, 4..6) at any level
local trapped = 0
for _, p in ipairs(CollectionService:GetTagged("Block")) do
	local x, z = p:GetAttribute("X"), p:GetAttribute("Z")
	if x >= 7 and x <= 9 and z >= 4 and z <= 6 then trapped = trapped + 1 end
end
check(trapped == 0, "spawn cells (7..9, 4..6) are clear of blocks")

-- tags
local nBlocks = #CollectionService:GetTagged("Block")
local nMine = #CollectionService:GetTagged("Mineable")
local nStations = #CollectionService:GetTagged("Station")
check(nBlocks == blockParts1 * 2, "every block part tagged Block (two runs: " .. nBlocks .. ")")
check(nMine > 0 and nMine < nBlocks, "Mineable subset present: " .. nMine)
check(nStations == 2 * 26, "26 stations per yard tagged Station (5+11+6+4 per band; got " .. nStations .. ")")

-- WorldModel
WorldModel.init(res1.level1)
check(WorldModel.isSolidAt(12, 8) == true, "isSolidAt(12,8) workbench solid")
check(WorldModel.isSolidAt(8, 5) == false, "isSolidAt(8,5) spawn cell clear")
check(WorldModel.isSolidAt(12.7, 8.9) == true, "isSolidAt floors fractional coords")
local d = WorldModel.distanceAhead(8, 5, 0)
check(type(d) == "number" and d >= 0 and d <= 1, "distanceAhead in [0,1]: " .. d)
local sx, sz = WorldModel.getSpawn()
check(sx == 12 and sz == 10, "getSpawn 2 south of workbench: " .. sx .. "," .. sz)

-- removeBlock: clears grid + destroys the part
local target
for _, p in ipairs(CollectionService:GetTagged("Block")) do
	if p:GetAttribute("X") == 12 and p:GetAttribute("Z") == 8 and p:GetAttribute("Level") == 1 then target = p end
end
WorldModel.removeBlock(12, 8, 1)
check(WorldModel.isSolidAt(12, 8) == false, "removeBlock clears occupancy")
check(target.Destroyed == true, "removeBlock destroys the Part")

-- sonar hits the bench row from spawn heading north (heading pi = -Z)
local d2 = WorldModel.distanceAhead(14, 12, math.pi) -- forge at (14,8), 4 cells north... z=12 looking -Z? heading pi: sin=0,cos=-1 -> -Z, forge at z=8 => 4 ahead
check(d2 < 1, "distanceAhead sees forge row from south: " .. d2)

print("PASS: smoke_pass2")
