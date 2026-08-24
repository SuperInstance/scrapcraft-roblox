--!strict
-- ProfileSchema.luau — player profile shape, defaults + sanitization (pure).
-- Phase 2 v1 subset of the shared-yard doc §7 datastore schema:
--   inventory (Items.luau ids → counts), gate state (greeted + day key),
--   editorProgram (the last SAVE & RUN tile program, plain data).
-- Bots/companion/spine/race arrive with their systems; sanitize() drops
-- unknown junk so a corrupted/tampered record can never brick a kid
-- (failure to load = fresh start at the gate, never a brick).
-- Headless-testable under lua5.1.

local ProfileSchema = {}

ProfileSchema.CURRENT_V = 1
ProfileSchema.MAX_ITEM_COUNT = 999      -- per-item clamp
ProfileSchema.MAX_ITEMS = 64            -- distinct item ids
ProfileSchema.PROGRAM_JSON_CAP = 65536  -- 64 KB — the kennel law's byte cap

function ProfileSchema.defaults(nowUnix: number?): any
	return {
		profile_v = ProfileSchema.CURRENT_V,
		lastSeenUnix = nowUnix or 0,
		inventory = {},
		greeted = false,     -- Earl's ceremony completed, ever
		gateDay = "",        -- "YYYY-MM-DD" of the last ceremony (day-greeting law)
		editorProgram = nil, -- last SAVE & RUN TileProgram tree (plain data)
	}
end

local function sanitizeInventory(raw: any): {[string]: number}
	local out: {[string]: number} = {}
	if type(raw) ~= "table" then return out end
	local n = 0
	for id, count in pairs(raw) do
		if n >= ProfileSchema.MAX_ITEMS then break end
		if type(id) == "string" and #id <= 32 and type(count) == "number" then
			local c = math.floor(count)
			if c > 0 then
				if c > ProfileSchema.MAX_ITEM_COUNT then c = ProfileSchema.MAX_ITEM_COUNT end
				out[id] = c
				n = n + 1
			end
		end
	end
	return out
end

-- TileProgram trees are plain data; validate structure + size without the
-- full BrainDoc whitelist (that gate runs at RUN time server-side anyway).
local function countNodes(list: any, depth: number): number
	if type(list) ~= "table" or depth > 16 then return 0 end
	local n = 0
	for _, node in ipairs(list) do
		if type(node) == "table" then
			n = n + 1
			n = n + countNodes(node.body, depth + 1)
			n = n + countNodes(node.elseBody, depth + 1)
		end
	end
	return n
end

local function sanitizeProgram(raw: any): any
	if type(raw) ~= "table" or type(raw.nodes) ~= "table" then return nil end
	local nodes = countNodes(raw.nodes, 0)
	if nodes == 0 or nodes > 128 then return nil end
	local name = type(raw.name) == "string" and raw.name:sub(1, 32) or "My Brain"
	return { name = name, brain = "tin", nodes = raw.nodes }
end

-- sanitize(rawRecord) → clean profile. Unknown fields dropped, known fields
-- type-checked/clamped, version gate: anything above CURRENT_V is truncated
-- down by field (a future version's fields disappear, not corrupt).
function ProfileSchema.sanitize(raw: any, nowUnix: number?): any
	local clean = ProfileSchema.defaults(nowUnix)
	if type(raw) ~= "table" then return clean end
	clean.inventory = sanitizeInventory(raw.inventory)
	if raw.greeted == true then clean.greeted = true end
	if type(raw.gateDay) == "string" and #raw.gateDay <= 10 then clean.gateDay = raw.gateDay end
	clean.editorProgram = sanitizeProgram(raw.editorProgram)
	if type(raw.lastSeenUnix) == "number" and raw.lastSeenUnix > 0 then
		clean.lastSeenUnix = raw.lastSeenUnix
	end
	return clean
end

-- Session lease logic (pure helper — PlayerDataService applies it in
-- UpdateAsync): returns "free" | "held" for a stored lease record vs now.
-- Lease held = another live server claimed it and it hasn't expired.
function ProfileSchema.leaseStatus(lease: any, selfServerId: string, nowUnix: number): string
	if type(lease) ~= "table" then return "free" end
	local expires = lease.expiresUnix
	if type(expires) ~= "number" or expires <= nowUnix then return "free" end
	if lease.serverId == selfServerId then return "mine" end
	return "held"
end

-- Day key for the gate's first-session-of-day law (UTC — matches the
-- weekly Monday-00:00-UTC board law in the shared-yard doc).
function ProfileSchema.dayKey(unixSeconds: number): string
	return os.date("!%Y-%m-%d", unixSeconds)
end

return ProfileSchema
