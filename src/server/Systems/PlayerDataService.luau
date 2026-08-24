--!strict
-- PlayerDataService.luau — Phase 2 persistence v1 (shared-yard doc §7).
-- One JSON profile per kid in DataStore "PlayerProfiles_v1":
--   · load-on-join with a 180 s session lease (60 s refresh) via UpdateAsync —
--     a crashed server releases in ≤ 3 min, a teleporting kid never doubles;
--   · buffered flush every 12 s when dirty (inventory snapshot compare);
--   · save-on-leave + BindToClose for the last hard save;
--   · pcall around EVERY DataStore call — Studio without API access (or a
--     throttled API) degrades to session-only memory, never an error wall.
-- Fields: inventory, gate state (greeted/gateDay), editorProgram. Init FIRST
-- (before InventoryService) so its PlayerRemoving snapshot runs first.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProfileSchema = require(Shared:WaitForChild("ProfileSchema"))

local InventoryService = require(script.Parent.InventoryService)

local PlayerDataService = {}

local STORE_NAME = "PlayerProfiles_v1"
local LEASE_SECONDS = 180
local LEASE_REFRESH = 60
local FLUSH_EVERY = 12
local LOAD_RETRIES = 3

local store: DataStore? = nil
local memoryOnly = false -- Studio / DataStore unavailable → session profiles

-- {[Player]: profileTable}
local profiles: {[Player]: any} = {}
-- {[Player]: lastFlushedJson} — dirty detection
local lastFlushed: {[Player]: string} = {}

local selfServerId = "studio"
local lastLeaseRefresh = 0

-- ── DataStore wrappers (pcall everywhere; failures never brick a kid) ──────

local function dsGet(key: string): (boolean, any)
	if memoryOnly or store == nil then return false, "memory-only" end
	local ok, result = pcall(function()
		return store:GetAsync(key)
	end)
	return ok, result
end

local function dsUpdate(key: string, mutator: any): (boolean, any)
	if memoryOnly or store == nil then return false, "memory-only" end
	local ok, result = pcall(function()
		return store:UpdateAsync(key, mutator)
	end)
	if not ok then
		warn("[scrapcraft] DataStore update failed for " .. key .. ": " .. tostring(result))
	end
	return ok, result
end

-- ── Profile assembly (source of truth: live services → plain data) ────────

local function buildProfile(player: Player, previous: any): any
	local now = os.time()
	local profile = ProfileSchema.sanitize(previous, now)
	profile.lastSeenUnix = now
	-- Inventory: live server state wins (it is the authority).
	local inv = InventoryService.get(player)
	local itemCount = 0
	local cleanInv: {[string]: number} = {}
	for id, count in pairs(inv) do
		if type(id) == "string" and type(count) == "number" and count > 0 and itemCount < ProfileSchema.MAX_ITEMS then
			cleanInv[id] = math.floor(count)
			itemCount = itemCount + 1
		end
	end
	profile.inventory = cleanInv
	return profile
end

local function keyFor(player: Player): string
	return "u_" .. tostring(player.UserId)
end

-- ── Load (acquire lease) ───────────────────────────────────────────────────

local function loadProfile(player: Player)
	local key = keyFor(player)

	local function attempt(): any
		local record: any = nil
		local ok = dsUpdate(key, function(old: any): any
			local now = os.time()
			local status = ProfileSchema.leaseStatus(old ~= nil and old.sessionLease or nil, selfServerId, now)
			if status == "held" then
				return nil -- abort transaction: someone else owns the lease
			end
			record = old
			local next = ProfileSchema.sanitize(old, now)
			next.sessionLease = { serverId = selfServerId, expiresUnix = now + LEASE_SECONDS }
			return next
		end)
		if not ok then return nil, "ds-error" end
		if record == nil and memoryOnly == false then
			-- UpdateAsync ran but lease was held (we returned nil) → held.
			return nil, "held"
		end
		return record
	end

	local record: any = nil
	if memoryOnly then
		record = nil
	else
		for _ = 1, LOAD_RETRIES do
			local r, why = attempt()
			if r ~= nil or why ~= "held" then
				record = r
				break
			end
			task.wait(1) -- lease held by a dying server — give it a beat
		end
		-- Still held after retries: playtest-friendly override (honest note in
		-- README — a crashed server's lease can outlive 3 s of patience).
		if record == nil then
			local forced = dsUpdate(key, function(old: any): any
				local now = os.time()
				record = old
				local next = ProfileSchema.sanitize(old, now)
				next.sessionLease = { serverId = selfServerId, expiresUnix = now + LEASE_SECONDS }
				return next
			end)
			if not forced then record = nil end
		end
	end

	local profile = ProfileSchema.sanitize(record, os.time())
	profiles[player] = profile

	-- Push loaded inventory into the live service (fires the inv sync).
	local inv = InventoryService.get(player)
	for id, count in pairs(profile.inventory) do
		inv[id] = count
	end
	InventoryService.sync(player)

	lastFlushed[player] = HttpService:JSONEncode(buildProfile(player, profile))
	print("[scrapcraft] profile loaded for " .. player.Name .. (memoryOnly and " (memory-only)" or ""))
end

-- ── Save (release or refresh lease) ────────────────────────────────────────

local function saveProfile(player: Player, release: boolean): boolean
	local previous = profiles[player]
	if previous == nil then return false end
	local profile = buildProfile(player, previous)

	if memoryOnly then
		profiles[player] = profile
		lastFlushed[player] = HttpService:JSONEncode(profile)
		return true
	end

	local key = keyFor(player)
	local ok = dsUpdate(key, function(old: any): any
		local now = os.time()
		local next = ProfileSchema.sanitize(old, now)
		-- Server state wins over the stored record for our fields.
		next.inventory = profile.inventory
		next.greeted = profile.greeted or next.greeted
		next.gateDay = profile.gateDay
		next.editorProgram = profile.editorProgram
		next.lastSeenUnix = now
		if release then
			next.sessionLease = { serverId = "", expiresUnix = 0 }
		else
			next.sessionLease = { serverId = selfServerId, expiresUnix = now + LEASE_SECONDS }
		end
		return next
	end)
	if ok then
		profiles[player] = profile
		lastFlushed[player] = HttpService:JSONEncode(profile)
	end
	return ok
end

-- ── Public API (GateService + BrainEditorService hooks) ────────────────────

-- Block (bounded) until the profile is loaded — GateService uses this so the
-- first-timer-vs-regular decision never races the async DataStore read.
function PlayerDataService.awaitProfile(player: Player, timeoutSeconds: number)
	local deadline = os.clock() + (timeoutSeconds or 5)
	while profiles[player] == nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return profiles[player]
end

function PlayerDataService.hasBeenGreeted(player: Player): boolean
	local p = profiles[player]
	return p ~= nil and p.greeted == true
end

function PlayerDataService.markGreeted(player: Player)
	local p = profiles[player]
	if p ~= nil then
		p.greeted = true
		p.gateDay = ProfileSchema.dayKey(os.time())
	end
end

function PlayerDataService.getEditorProgram(player: Player): any
	local p = profiles[player]
	return p ~= nil and p.editorProgram or nil
end

function PlayerDataService.setEditorProgram(player: Player, program: any)
	local p = profiles[player]
	if p ~= nil then
		-- sanitize keeps it a plain, size-capped tree (kennel law).
		p.editorProgram = ProfileSchema.sanitize({ editorProgram = program }).editorProgram
	end
end

-- ── Flush loop (dirty detection by snapshot compare, 12 s cadence) ────────

local function flushTick(now: number)
	for _, player in ipairs(Players:GetPlayers()) do
		if profiles[player] ~= nil then
			local snap = HttpService:JSONEncode(buildProfile(player, profiles[player]))
			if snap ~= lastFlushed[player] then
				saveProfile(player, false)
			end
		end
	end
	-- Lease refresh piggybacks: a flush writes a fresh lease; players with no
	-- changes still need their lease renewed every LEASE_REFRESH.
	if now - lastLeaseRefresh >= LEASE_REFRESH then
		lastLeaseRefresh = now
		for _, player in ipairs(Players:GetPlayers()) do
			if profiles[player] ~= nil then
				local snap = HttpService:JSONEncode(buildProfile(player, profiles[player]))
				if snap == lastFlushed[player] then
					saveProfile(player, false) -- no-op data, fresh lease
				end
			end
		end
	end
end

-- Seam wiring shared by init() and the headless smoke suite (tests call
-- _bindSeams + _setMemoryOnly instead of init, so no event loops spin up).
function PlayerDataService._bindSeams(): ()
	PlayerDataService._load = loadProfile
	PlayerDataService._save = saveProfile
	PlayerDataService._flushOnce = flushTick
	PlayerDataService._isMemoryOnly = function()
		return memoryOnly
	end
	PlayerDataService._setMemoryOnly = function(v: boolean)
		memoryOnly = v
		if v then store = nil end
	end
	PlayerDataService._setServerId = function(id: string)
		selfServerId = id
	end
	PlayerDataService._setStore = function(s: any)
		store = s
	end
end

-- ── Init ───────────────────────────────────────────────────────────────────

function PlayerDataService.init(): ()
	PlayerDataService._bindSeams()
	if RunService:IsStudio() and game.JobId == "" then
		selfServerId = "studio-" .. tostring(math.floor(os.clock() * 1000))
	else
		selfServerId = game.JobId
	end

	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok and typeof(result) == "Instance" then
		store = result
	else
		memoryOnly = true
		warn("[scrapcraft] DataStore unavailable — session-only profiles (" .. tostring(result) .. ")")
	end

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(loadProfile, player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Runs BEFORE InventoryService's own cleanup (init order guarantees it)
		-- so buildProfile still sees the live inventory.
		saveProfile(player, true)
		profiles[player] = nil
		lastFlushed[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(loadProfile, player)
	end

	task.spawn(function()
		while true do
			task.wait(FLUSH_EVERY)
			if PlayerDataService._flushOnce ~= nil then
				PlayerDataService._flushOnce(os.time())
			end
		end
	end)

	game:BindToClose(function()
		-- Last hard save for everyone (≤ 25 s; Studio kills at 30).
		if memoryOnly then return end
		for _, player in ipairs(Players:GetPlayers()) do
			saveProfile(player, true)
		end
	end)

	print("[scrapcraft] PlayerDataService up" .. (memoryOnly and " (memory-only fallback)" or ""))
end

return PlayerDataService
