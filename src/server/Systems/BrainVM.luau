--!strict
-- BrainVM.luau — Phase 1 tile-program VM + VirtualRobot, ported exactly.
-- Sources of truth (docs/SPEC-pass3-brain.md):
--   VirtualRobot.js — pose + persistent motor state + axis-separated slide
--   TileVM.js       — execution model: WAIT yields (motors stay set),
--                     forever = ONE PASS PER TICK, budget cap, HALT cuts
--                     motors, unknown op skips/halts safely
--   primitives.js   — ACTUATORS drive/turn/stop/beep/led semantics.
--                     IMPORTANT: `drive` does NOT zero turnPower and vice
--                     versa — motor pins stay set until changed (only
--                     `stop` clears both). Ported as-is.
--   index.js MakerRuntime.tick — vm.step(dt) THEN robot.tick(dt).
--
-- Phase 1 node subset: action | wait | forever | if_else.
-- Sensor subset: distance_ahead (unknown sensor reads 0, like TileVM._read).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local WorldModel = require(script.Parent.WorldModel)

local BrainVM = {}

local DEG2RAD = math.pi / 180

-- TileVM.js MAX_STEPS_PER_TICK
local BUDGET = 4096

local function clamp(v: number, lo: number, hi: number): number
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- ── VirtualRobot (VirtualRobot.js verbatim) ────────────────────────────────
-- The original takes a `world` per tick; Phase 1 binds WorldModel directly
-- (it is the GameWorldAdapter — spec: "Do not modify them").

local Robot = {}
Robot.__index = Robot

function Robot.new(spawnState: {[string]: any})
	local self = setmetatable({}, Robot)
	self.x = spawnState.x or 0
	self.z = spawnState.z or 0
	self.heading = spawnState.heading or 0 -- radians; 0 faces +Z
	self.drivePower = 0                    -- [-1, 1]
	self.turnPower = 0                     -- [-1, 1]; right(+)/left(-)
	self.gripping = false
	self.led = "off"
	self.events = {}
	return self
end

function Robot:setDrive(v: number)
	self.drivePower = clamp(v, -1, 1)
end

function Robot:setTurn(v: number)
	self.turnPower = clamp(v, -1, 1)
end

function Robot:emit(kind: string, data: {[string]: any})
	if kind == "led" and data.state ~= nil then
		self.led = data.state
	end
	table.insert(self.events, { kind = kind, pitch = data.pitch, state = data.state })
end

function Robot:drainEvents()
	local e = self.events
	self.events = {}
	return e
end

-- blocked() verbatim: 4 samples at BOT_RADIUS.
local function blocked(x: number, z: number): boolean
	local r = Config.BOT_RADIUS
	if WorldModel.isSolidAt(x + r, z) then return true end
	if WorldModel.isSolidAt(x - r, z) then return true end
	if WorldModel.isSolidAt(x, z + r) then return true end
	if WorldModel.isSolidAt(x, z - r) then return true end
	return false
end

-- tick(dt): rotation first (wrap to [-pi, pi] exactly like the original),
-- then translation with axis-separated slide (2nd check uses UPDATED x).
function Robot:tick(dt: number)
	if self.turnPower ~= 0 then
		self.heading = self.heading + self.turnPower * Config.TURN_RATE * DEG2RAD * dt
		if self.heading > math.pi then self.heading = self.heading - 2 * math.pi end
		if self.heading < -math.pi then self.heading = self.heading + 2 * math.pi end
	end
	if self.drivePower ~= 0 then
		local dist = self.drivePower * Config.DRIVE_SPEED * dt
		local nx = self.x + math.sin(self.heading) * dist
		local nz = self.z + math.cos(self.heading) * dist
		if not blocked(nx, self.z) then self.x = nx end
		if not blocked(self.x, nz) then self.z = nz end
	end
end

-- ── Actuators (primitives.js ACTUATORS — exact) ────────────────────────────
-- drive/turn set ONLY their own power (pins stay set); stop clears both.

local ACTUATORS = {
	["drive"] = function(robot, p)
		local speed = p.speed or 0.5
		robot:setDrive(p.dir == "forward" and speed or -speed)
	end,
	["turn"] = function(robot, p)
		local speed = p.speed or 0.5
		robot:setTurn(p.dir == "right" and speed or -speed)
	end,
	["stop"] = function(robot, p)
		robot:setDrive(0)
		robot:setTurn(0)
	end,
	["beep"] = function(robot, p)
		robot:emit("beep", { pitch = p.pitch })
	end,
	["led"] = function(robot, p)
		robot:emit("led", { state = p.state })
	end,
}

-- ── Conditions / sensors ───────────────────────────────────────────────────

local function compare(a: number, b: number, cmp: string): boolean
	if cmp == "gt" then return a > b end
	if cmp == "lt" then return a < b end
	if cmp == "gte" then return a >= b end
	if cmp == "lte" then return a <= b end
	if cmp == "eq" then return a == b end
	if cmp == "neq" then return a ~= b end
	if cmp == "is" then return a == b end
	return false
end

-- TileVM._read: unknown sensor → 0 (no crash).
local function readSensor(id: string, robot): number
	if id == "distance_ahead" then
		return WorldModel.distanceAhead(robot.x, robot.z, robot.heading)
	end
	return 0
end

local function evalCond(cond, robot): boolean
	if typeof(cond) ~= "table" then return false end
	local v = readSensor(cond.sensor, robot)
	return compare(v, cond.value, cond.cmp)
end

-- ── The VM (tree interpreter; TileVM semantics on the Phase-1 subset) ──────

local VM = {}
VM.__index = VM

function BrainVM.new(program, spawnState)
	local self = setmetatable({}, VM)
	self.robot = Robot.new(spawnState or {})
	self.program = program
	-- Frame stack: { kind = "list"|"forever", nodes = {...}, i = cursor }.
	-- Root frame holds program.nodes; exhausting it ends the program (HALT).
	self.frames = { { kind = "list", nodes = program.nodes or {}, i = 1 } }
	self.waitTimer = 0
	self.yield = false
	self.dead = false
	self.errors = {}
	self.steps = 0
	return self
end

function VM:halt()
	self.dead = true
	self.yield = true
	-- TileVM HALT safety: cut motors when a program ends.
	self.robot:setDrive(0)
	self.robot:setTurn(0)
end

function VM:error(msg: string)
	table.insert(self.errors, msg)
	self:halt()
end

-- Execute one node (or frame transition). Yields: WAIT set, forever pass
-- completed. Re-checks if_else conditions every iteration (like the JS VM).
function VM:execNext()
	local frames = self.frames
	local frame = frames[#frames]
	if frame == nil then
		self:halt() -- fell off the end of the program
		return
	end
	self.steps = self.steps + 1

	local node = frame.nodes[frame.i]
	if node == nil then
		-- Frame exhausted.
		if frame.kind == "forever" then
			frame.i = 1       -- next pass …
			self.yield = true -- …but one endless-loop pass per tick (NEXT)
		else
			table.remove(frames) -- pop; parent cursor already advanced
		end
		return
	end

	local ntype = typeof(node) == "table" and node.type or nil
	if ntype == "action" then
		local prim = ACTUATORS[node.prim]
		if prim == nil then
			self:error("unknown primitive: " .. tostring(node.prim))
			return
		end
		prim(self.robot, node.params or {})
		frame.i = frame.i + 1
	elseif ntype == "wait" then
		self.waitTimer = math.max(0, node.seconds or 0)
		frame.i = frame.i + 1 -- resume AFTER the wait
		self.yield = true     -- give the frame back
	elseif ntype == "forever" then
		frame.i = frame.i + 1
		table.insert(frames, { kind = "forever", nodes = node.body or {}, i = 1 })
	elseif ntype == "if_else" then
		frame.i = frame.i + 1
		local body = evalCond(node.cond, self.robot) and node.body or node.elseBody
		table.insert(frames, { kind = "list", nodes = body or {}, i = 1 })
	else
		self:error("unknown node type: " .. tostring(ntype))
		return
	end
end

-- MakerRuntime.tick order: advance the VM, then integrate robot physics.
function VM:step(dt: number)
	if self.dead then return end

	-- Honor an in-progress WAIT first (TileVM.step). Motors stay set while
	-- waiting — the robot's own tick handles motion; nothing to re-issue.
	if self.waitTimer > 0 then
		self.waitTimer = self.waitTimer - dt
		if self.waitTimer > 0 then
			self.robot:tick(dt)
			return
		end
		self.waitTimer = 0
		-- wait expired this frame → fall through and continue executing
	end

	self.yield = false
	local budget = BUDGET
	while not self.yield and not self.dead and budget > 0 do
		budget = budget - 1
		self:execNext()
	end

	self.robot:tick(dt)
end

return BrainVM
