--!strict
-- GateQueue.luau — Earl's gate queue, PURE LOGIC (no Roblox API).
-- The queue IS the ceremony (docs/PHASE2-SHARED-YARD.md §3): max 7 visible
-- numbered positions, one greeted player at a time, idle drift (one position
-- back per 90 s), and a gate bell cooldown (first in line, 3 rings max).
--
-- Keys are opaque player identifiers (UserId in prod, strings in tests).
-- Headless-testable under lua5.1.

local GateQueue = {}

GateQueue.MAX_VISIBLE = 7
GateQueue.IDLE_DRIFT_SECONDS = 90  -- idle players drift back one position
GateQueue.BELL_COOLDOWN = 4       -- seconds between rings
GateQueue.BELL_MAX_RINGS = 3      -- tradition: three rings, that's the rite

function GateQueue.new()
	return {
		order = {},             -- {key, ...} front first
		joinedAt = {},          -- {[key]: unixSeconds}
		lastActive = {},        -- {[key]: unixSeconds} — touch() on movement
		bellRings = 0,          -- rings by the CURRENT front (reset on advance)
		bellLastAt = 0,
	}
end

local function indexOf(q: any, key: any): number?
	for i, k in ipairs(q.order) do
		if k == key then return i end
	end
	return nil
end

-- Join the back of the line. Returns the 1-based position. Re-join is a no-op
-- that returns the existing position.
function GateQueue.join(q: any, key: any, now: number): number
	local existing = indexOf(q, key)
	if existing ~= nil then return existing end
	table.insert(q.order, key)
	q.joinedAt[key] = now
	q.lastActive[key] = now
	return #q.order
end

function GateQueue.leave(q: any, key: any)
	local i = indexOf(q, key)
	if i == nil then return end
	table.remove(q.order, i)
	q.joinedAt[key] = nil
	q.lastActive[key] = nil
end

-- Front of the line (the player being / about to be greeted), or nil.
function GateQueue.front(q: any): any
	return q.order[1]
end

-- The greeted player walked through — next!
function GateQueue.advance(q: any)
	local wasFront = table.remove(q.order, 1)
	if wasFront ~= nil then
		q.joinedAt[wasFront] = nil
		q.lastActive[wasFront] = nil
	end
	q.bellRings = 0
	q.bellLastAt = 0
	return wasFront
end

function GateQueue.positionOf(q: any, key: any): number?
	return indexOf(q, key)
end

-- Full ordered snapshot (all joiners; caller renders only the first 7).
function GateQueue.snapshot(q: any): { any }
	local out = {}
	for i, k in ipairs(q.order) do out[i] = k end
	return out
end

-- Movement/activity ping (call on character movement or any input).
function GateQueue.touch(q: any, key: any, now: number)
	if q.lastActive[key] ~= nil then
		q.lastActive[key] = now
	end
end

-- Idle drift: every IDLE_DRIFT_SECONDS without a touch, slide back one
-- position (swap with the neighbor behind). Returns keys that drifted so the
-- caller can update hard-hat billboards. Call ~1×/s.
function GateQueue.idleTick(q: any, now: number): { any }
	local drifted = {}
	-- Every idle player drifts one position back per window — including the
	-- front (the ceremony marks its player active; a truly idle front yields
	-- the mic. The gate is patient, not frozen.) The LAST position can't
	-- drift (nobody behind to swap with).
	local i = #q.order - 1
	while i >= 1 do
		local key = q.order[i]
		local last = q.lastActive[key] or q.joinedAt[key] or now
		if now - last >= GateQueue.IDLE_DRIFT_SECONDS then
			q.order[i], q.order[i + 1] = q.order[i + 1], q.order[i]
			q.lastActive[key] = now -- drift resets the idle timer
			table.insert(drifted, key)
		end
		i = i - 1
	end
	return drifted
end

-- The bell: only the front may ring, cooldown between rings, 3 rings per
-- turn (tradition). Returns ok, errOrNil. Caller plays the sound + toast.
function GateQueue.ringBell(q: any, key: any, now: number): (boolean, string?)
	if key ~= q.order[1] then
		return false, "the bell belongs to whoever's first in line"
	end
	if q.bellRings >= GateQueue.BELL_MAX_RINGS then
		return false, "three rings is the rite — save some bell for the next kid"
	end
	if now - q.bellLastAt < GateQueue.BELL_COOLDOWN then
		return false, "easy — let the bell settle"
	end
	q.bellRings = q.bellRings + 1
	q.bellLastAt = now
	return true, nil
end

return GateQueue
