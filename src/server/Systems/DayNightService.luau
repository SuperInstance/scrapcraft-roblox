--!strict
-- DayNightService.luau — server heartbeat day/night cycle.
-- Port of src/DayNight.js: CYCLE = 360 s (Config.DAY_CYCLE_SECONDS), start
-- t = 0.35 "morning" (DayNight.js L35), isNight t < 0.25 or t > 0.78 (L59).
-- Mapped to Roblox: Lighting.ClockTime = t * 24; ambient lerped between
-- night dark-navy (40,45,80) and day (150,140,120).

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DayNightService = {}

local t = Config.DAY_START_T -- DayNight.js L35: this._time = 0.35 (morning)

local NIGHT_AMBIENT = Color3.fromRGB(40, 45, 80) -- spec: dark navy
local DAY_AMBIENT = Color3.fromRGB(150, 140, 120)

-- DayNight.js keyframes put sunrise at t≈0.28 and dusk at t≈0.82; blend the
-- ambient across a small window around the isNight boundaries (0.25 / 0.78)
-- so the lerp is smooth instead of a hard switch.
local TRANSITION = 0.04

local function clamp01(v: number): number
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

-- 1 = full day, 0 = full night (smoothstep through the boundary windows).
local function dayFactor(time: number): number
	local lin: number
	if time < 0.5 then
		-- dawn ramp: night → day across [0.25 - TRANSITION, 0.25 + TRANSITION]
		lin = clamp01((time - (Config.NIGHT_T_MAX - TRANSITION)) / (2 * TRANSITION))
	else
		-- dusk ramp: day → night across [0.78 - TRANSITION, 0.78 + TRANSITION]
		lin = 1 - clamp01((time - (Config.NIGHT_T_MIN - TRANSITION)) / (2 * TRANSITION))
	end
	return lin * lin * (3 - 2 * lin)
end

--- 0–1 position in the day cycle.
function DayNightService.getT(): number
	return t
end

--- DayNight.js L59: `this._time < 0.25 || this._time > 0.78` (Config values).
function DayNightService.isNight(): boolean
	return t < Config.NIGHT_T_MAX or t > Config.NIGHT_T_MIN
end

function DayNightService.init(): ()
	-- Atmosphere hint (created once; density thickens slightly at night).
	local existing = Lighting:FindFirstChildOfClass("Atmosphere")
	local atmosphere: Atmosphere
	if existing ~= nil then
		atmosphere = existing
	else
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end

	RunService.Heartbeat:Connect(function(dt: number)
		-- DayNight.js L72: this._time = (this._time + dt / CYCLE) % 1
		t = (t + dt / Config.DAY_CYCLE_SECONDS) % 1

		Lighting.ClockTime = t * 24

		local d = dayFactor(t)
		local ambient = NIGHT_AMBIENT:Lerp(DAY_AMBIENT, d)
		Lighting.Ambient = ambient
		Lighting.OutdoorAmbient = ambient
		atmosphere.Density = 0.3 + 0.15 * (1 - d)
	end)
end

return DayNightService
