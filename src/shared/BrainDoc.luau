--!strict
-- BrainDoc.luau — the tile-editor DOCUMENT MODEL (pure data, no Roblox API).
--
-- The Phase 2 visual brain editor ("the crown jewel") edits a node GRAPH that
-- serializes to EXACTLY the program tree BrainVM executes:
--     { name, brain, nodes = { action|wait|forever|if_else … } }
-- (same shape as shared/TileProgram.luau STARTER_* and the web TileProgram
-- schema in ../Scrapcraft/src/maker/TileProgram.js, Phase 1 VM subset).
--
-- Graph model: every node has an IN port and a NEXT out port; `forever` adds
-- a BODY out port; `if_else` adds BODY (then) + ELSE out ports. A wire goes
-- out-port → in-port. The graph must stay a TREE (the loop is `forever`, not
-- a back-edge) — wiring into your own descendant is rejected.
--
-- Node positions (x, y in canvas px) are purely cosmetic; serialization
-- follows wires only. This module is headless-testable under lua5.1.

local BrainDoc = {}

-- ── Limits (server-side validation + editor guards) ────────────────────────
BrainDoc.MAX_NODES = 128        -- editor refuses to add past this
BrainDoc.MAX_DEPTH = 12         -- nested body depth (forever/if_else)
BrainDoc.MAX_SECONDS = 30       -- wait clamp (one-pass-per-tick forever stays honest)
BrainDoc.MAX_NAME_LEN = 32

-- Whitelists — mirror BrainVM's Phase 1 subset exactly.
BrainDoc.PRIMS = { drive = true, turn = true, stop = true, beep = true, led = true }
BrainDoc.SENSORS = { distance_ahead = true }
BrainDoc.CMPS = { lt = true, gt = true, lte = true, gte = true, eq = true, neq = true, is = true }
BrainDoc.DIRS = { forward = true, back = true }
BrainDoc.TURN_DIRS = { left = true, right = true }
BrainDoc.PITCHES = { low = true, mid = true, high = true }
BrainDoc.LED_STATES = { off = true, on = true }

-- Port colors (editor rendering: next=cyan, body=purple, else=red).
BrainDoc.PORT_NEXT, BrainDoc.PORT_BODY, BrainDoc.PORT_ELSE = "next", "body", "else"

local PORTS_BY_TYPE: {[string]: {string}} = {
	action = { "next" },
	wait = { "next" },
	forever = { "next", "body" },
	if_else = { "next", "body", "else" },
}

local function isPortOf(nodeType: string, port: string): boolean
	local ports = PORTS_BY_TYPE[nodeType]
	if ports == nil then return false end
	for _, p in ipairs(ports) do
		if p == port then return true end
	end
	return false
end

local function clampNumber(v: number, lo: number, hi: number): number
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- ── Document construction ──────────────────────────────────────────────────

function BrainDoc.new(name: string?)
	return {
		name = (name or "Untitled Brain"):sub(1, BrainDoc.MAX_NAME_LEN),
		brain = "tin",
		head = nil :: number?, -- in-port id of the root sequence head
		nodes = {} :: {[number]: any},
		nextId = 1,
	}
end

function BrainDoc.addNode(doc: any, nodeType: string, x: number, y: number): number
	if PORTS_BY_TYPE[nodeType] == nil then
		error("BrainDoc.addNode: unknown node type " .. tostring(nodeType))
	end
	local count = 0
	for _ in pairs(doc.nodes) do count = count + 1 end
	if count >= BrainDoc.MAX_NODES then
		error("BrainDoc.addNode: program full (max " .. BrainDoc.MAX_NODES .. " tiles)")
	end
	local id = doc.nextId
	doc.nextId = id + 1
	local node: any = { id = id, type = nodeType, x = x, y = y, next = nil }
	if nodeType == "action" then
		node.prim, node.params = "drive", { dir = "forward", speed = 0.5 }
	elseif nodeType == "wait" then
		node.seconds = 0.5
	elseif nodeType == "if_else" then
		node.cond = { sensor = "distance_ahead", cmp = "lt", value = 0.25 }
		node.elseBody = nil
	end
	doc.nodes[id] = node
	return id
end

-- Remove a node; anything that wired INTO it rewires to the node's own next
-- (splice-out, like deleting a list cell). head splices too.
function BrainDoc.removeNode(doc: any, id: number)
	local node = doc.nodes[id]
	if node == nil then return end
	local successor = node.next
	-- head splices to the removed node's own next, like every other wire.
	if doc.head == id then doc.head = successor end
	for _, other in pairs(doc.nodes) do
		if other.id ~= id then
			for _, ref in ipairs({ "next", "body", "elseBody" }) do
				if other[ref] == id then other[ref] = successor end
			end
		end
	end
	doc.nodes[id] = nil
end

-- ── Param editing (clamped + whitelisted; editor controls call these) ──────

local function defaultParams(prim: string): {[string]: any}
	if prim == "drive" then return { dir = "forward", speed = 0.5 } end
	if prim == "turn" then return { dir = "right", speed = 0.5 } end
	if prim == "beep" then return { pitch = "high" } end
	if prim == "led" then return { state = "on" } end
	return {} -- stop
end

function BrainDoc.setPrim(doc: any, id: number, prim: string)
	local node = doc.nodes[id]
	if node == nil or node.type ~= "action" or not BrainDoc.PRIMS[prim] then return end
	node.prim = prim
	node.params = defaultParams(prim)
end

function BrainDoc.setParam(doc: any, id: number, key: string, value: any)
	local node = doc.nodes[id]
	if node == nil then return end
	if node.type == "wait" and key == "seconds" then
		if type(value) == "number" then node.seconds = clampNumber(value, 0, BrainDoc.MAX_SECONDS) end
	elseif node.type == "action" and node.params ~= nil then
		local p = node.params
		if key == "speed" and type(value) == "number" then
			p.speed = clampNumber(value, 0, 1)
		elseif key == "dir" and (value == "forward" or value == "back") then
			p.dir = value
		elseif key == "dir" and (value == "left" or value == "right") then
			p.dir = value
		elseif key == "pitch" and BrainDoc.PITCHES[value] then
			p.pitch = value
		elseif key == "state" and BrainDoc.LED_STATES[value] then
			p.state = value
		end
	elseif node.type == "if_else" and node.cond ~= nil then
		local c = node.cond
		if key == "sensor" and BrainDoc.SENSORS[value] then c.sensor = value
		elseif key == "cmp" and BrainDoc.CMPS[value] then c.cmp = value
		elseif key == "value" and type(value) == "number" then c.value = clampNumber(value, 0, 1)
		end
	end
end

function BrainDoc.setName(doc: any, name: string)
	doc.name = name:sub(1, BrainDoc.MAX_NAME_LEN)
end

-- ── Wiring (tree invariants enforced) ──────────────────────────────────────

-- Is `maybeAncestor` == id or an ancestor of id following any out-port?
local function reaches(fromId: number, id: number, nodes: any, seen: {[number]: boolean}): boolean
	if fromId == id then return true end
	if seen[fromId] then return false end -- defensive: doc invariants prevent cycles already
	seen[fromId] = true
	local node = nodes[fromId]
	if node == nil then return false end
	for _, ref in ipairs({ "next", "body", "elseBody" }) do
		local child = node[ref]
		if child ~= nil and reaches(child, id, nodes, seen) then return true end
	end
	return false
end

-- Wire (fromId, port) → toId. out-port holds ONE wire (a new wire replaces
-- the old). Rejects: unknown port, self-wire, wiring into your own subtree
-- (would create a cycle / non-tree), wiring two out-ports of the SAME node
-- into the same target (a node needs exactly one parent).
-- Returns ok, err.
function BrainDoc.wire(doc: any, fromId: number, port: string, toId: number): (boolean, string?)
	local from = doc.nodes[fromId]
	local to = doc.nodes[toId]
	if from == nil or to == nil then return false, "no such node" end
	if fromId == toId then return false, "can't wire a tile to itself" end
	if not isPortOf(from.type, port) then return false, "bad port for " .. from.type end
	if port == "else" and from.type ~= "if_else" then return false, "bad port" end
	-- Rewiring replaces the old wire: detach it FIRST so the cycle check
	-- below sees the post-rewrite graph (rewire a→c past b is legal).
	local field = port == "else" and "elseBody" or port -- node field name
	local oldTarget = from[field]
	from[field] = nil
	-- Tree rules (both directions — a tree has no cycles and no diamonds):
	--   toId inside from's subtree  → diamond/loop;
	--   from inside toId's subtree  → wiring into your own ancestor = loop.
	local loops = reaches(fromId, toId, doc.nodes, {}) or reaches(toId, fromId, doc.nodes, {})
	if loops then
		from[field] = oldTarget
		return false, "that would loop — use Forever for loops"
	end
	-- Single-parent rule: detach toId from any current parent port.
	for _, other in pairs(doc.nodes) do
		for _, ref in ipairs({ "next", "body", "elseBody" }) do
			if other[ref] == toId then other[ref] = nil end
		end
	end
	if doc.head == toId then doc.head = nil end
	from[field] = toId
	return true, nil
end

-- Make toId the root head (its in-port binds to the document root).
function BrainDoc.setHead(doc: any, id: number)
	local node = doc.nodes[id]
	if node == nil then return end
	for _, other in pairs(doc.nodes) do
		for _, ref in ipairs({ "next", "body", "elseBody" }) do
			if other[ref] == id then other[ref] = nil end
		end
	end
	doc.head = id
end

-- ── Serialization: doc graph → BrainVM program tree ────────────────────────
-- chainInto walks a chain (startId … .next …) emitting nodes; container
-- bodies recurse with depth+1. Orphan/dangling ids simply end the chain.

local function chainInto(nodes: any, startId: number?, depth: number, out: { any }, stats: any)
	if depth > BrainDoc.MAX_DEPTH then
		error("serialize: nested too deep (max " .. BrainDoc.MAX_DEPTH .. ")")
	end
	local id = startId
	local guard = 0
	while id ~= nil do
		guard = guard + 1
		if guard > BrainDoc.MAX_NODES then error("serialize: chain runaway") end
		local node = nodes[id]
		if node == nil then break end -- dangling wire — chain ends
		stats.count = stats.count + 1
		if node.type == "action" then
			local params: {[string]: any} = {}
			for k, v in pairs(node.params or {}) do params[k] = v end
			table.insert(out, { type = "action", prim = node.prim, params = params })
		elseif node.type == "wait" then
			table.insert(out, { type = "wait", seconds = node.seconds or 0 })
		elseif node.type == "forever" then
			local body: { any } = {}
			chainInto(nodes, node.body, depth + 1, body, stats)
			table.insert(out, { type = "forever", body = body })
		elseif node.type == "if_else" then
			local body: { any } = {}
			local elseBody: { any } = {}
			chainInto(nodes, node.body, depth + 1, body, stats)
			chainInto(nodes, node.elseBody, depth + 1, elseBody, stats)
			local cond = node.cond or {}
			table.insert(out, {
				type = "if_else",
				cond = { sensor = cond.sensor, cmp = cond.cmp, value = cond.value },
				body = body, elseBody = elseBody,
			})
		else
			error("serialize: unknown node type " .. tostring(node.type))
		end
		id = node.next
	end
end

-- Serialize the ROOT chain (doc.head). Orphan nodes are ignored (they stay in
-- the doc for the editor; the program only contains what's wired from head).
function BrainDoc.serialize(doc: any): any
	local stats = { count = 0 }
	local nodes: { any } = {}
	chainInto(doc.nodes, doc.head, 0, nodes, stats)
	return {
		name = doc.name,
		brain = doc.brain,
		nodes = nodes,
	}
end

-- ── Load: BrainVM program tree → doc (auto-layout, DFS) ────────────────────
-- Column x = depth * 190, row y = visit order * 100. Positions are cosmetic.

function BrainDoc.load(program: any): any
	local doc = BrainDoc.new(program.name)
	local cursor = { y = 0 }

	local function placeChain(list: { any }, depth: number): number?
		local prevId: number? = nil
		local headId: number? = nil
		for _, treeNode in ipairs(list or {}) do
			local ntype = treeNode.type
			if PORTS_BY_TYPE[ntype] ~= nil then
				local id = BrainDoc.addNode(doc, ntype, 40 + depth * 190, 40 + cursor.y * 100)
				cursor.y = cursor.y + 1
				local node = doc.nodes[id]
				if ntype == "action" then
					BrainDoc.setPrim(doc, id, treeNode.prim)
					local p = treeNode.params or {}
					for k, v in pairs(p) do BrainDoc.setParam(doc, id, k, v) end
				elseif ntype == "wait" then
					BrainDoc.setParam(doc, id, "seconds", treeNode.seconds or 0)
				elseif ntype == "if_else" then
					local c = treeNode.cond or {}
					BrainDoc.setParam(doc, id, "sensor", c.sensor)
					BrainDoc.setParam(doc, id, "cmp", c.cmp)
					BrainDoc.setParam(doc, id, "value", c.value)
					node.body = placeChain(treeNode.body, depth + 1)
					node.elseBody = placeChain(treeNode.elseBody, depth + 1)
				elseif ntype == "forever" then
					node.body = placeChain(treeNode.body, depth + 1)
				end
				if prevId ~= nil then
					doc.nodes[prevId].next = id
				else
					headId = id
				end
				prevId = id
			end
		end
		return headId
	end

	doc.head = placeChain(program.nodes or {}, 0)
	return doc
end

-- ── Validation: a program table (untrusted, from the network) → ok/errs ────
-- Server gate before BrainVM.new. Whitelist every type, prim, param, cond;
-- clamp numbers; cap nodes + depth. Returns { ok = bool, errors = {…}, count }.

function BrainDoc.validate(program: any): any
	local result = { ok = true, errors = {}, count = 0 }
	if type(program) ~= "table" then
		result.ok = false
		table.insert(result.errors, "program must be a table")
		return result
	end
	if program.brain ~= nil and program.brain ~= "tin" then
		result.ok = false
		table.insert(result.errors, "only tin brains exist in Phase 1")
	end

	local function bad(msg: string)
		result.ok = false
		table.insert(result.errors, msg)
	end

	local function checkList(list: any, depth: number, path: string)
		if depth > BrainDoc.MAX_DEPTH then bad(path .. ": nested too deep") return end
		if type(list) ~= "table" then bad(path .. ": not a list") return end
		if #list > BrainDoc.MAX_NODES then bad(path .. ": too many tiles (max " .. BrainDoc.MAX_NODES .. ")") return end
		for i, node in ipairs(list) do
			local npath = path .. "[" .. i .. "]"
			result.count = result.count + 1
			if result.count > BrainDoc.MAX_NODES then bad("too many tiles total") return end
			local ntype = type(node) == "table" and node.type or nil
			if ntype == nil then
				bad(npath .. ": not a node")
			elseif ntype == "action" then
				if not BrainDoc.PRIMS[node.prim] then
					bad(npath .. ": unknown action '" .. tostring(node.prim) .. "'")
				else
					local p = node.params
					if p ~= nil and type(p) ~= "table" then
						bad(npath .. ": params must be a table")
					else
						p = p or {}
						if p.speed ~= nil and (type(p.speed) ~= "number" or p.speed < 0 or p.speed > 1) then
							bad(npath .. ": speed must be 0..1")
						end
						if p.dir ~= nil and not (BrainDoc.DIRS[p.dir] or BrainDoc.TURN_DIRS[p.dir]) then
							bad(npath .. ": bad dir '" .. tostring(p.dir) .. "'")
						end
						if p.pitch ~= nil and not BrainDoc.PITCHES[p.pitch] then
							bad(npath .. ": bad pitch")
						end
						if p.state ~= nil and not BrainDoc.LED_STATES[p.state] then
							bad(npath .. ": bad led state")
						end
					end
				end
			elseif ntype == "wait" then
				if type(node.seconds) ~= "number" then bad(npath .. ": wait needs seconds (number)")
				elseif node.seconds < 0 or node.seconds > BrainDoc.MAX_SECONDS then
					bad(npath .. ": wait seconds must be 0.." .. BrainDoc.MAX_SECONDS)
				end
			elseif ntype == "forever" then
				checkList(node.body, depth + 1, npath .. ".body")
			elseif ntype == "if_else" then
				local c = node.cond
				if type(c) ~= "table" then
					bad(npath .. ": if needs a condition")
				else
					if not BrainDoc.SENSORS[c.sensor] then bad(npath .. ": unknown sensor '" .. tostring(c.sensor) .. "'") end
					if not BrainDoc.CMPS[c.cmp] then bad(npath .. ": unknown compare '" .. tostring(c.cmp) .. "'") end
					if type(c.value) ~= "number" or c.value < 0 or c.value > 1 then
						bad(npath .. ": compare value must be 0..1")
					end
				end
				checkList(node.body, depth + 1, npath .. ".body")
				checkList(node.elseBody, depth + 1, npath .. ".elseBody")
			else
				bad(npath .. ": unknown tile type '" .. tostring(ntype) .. "'")
			end
		end
	end

	checkList(program.nodes, 0, "nodes")
	return result
end

-- Deep-equal helper for tests (program trees: ordered arrays, scalar leaves).
function BrainDoc.programsEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	local na, nb = 0, 0
	for k in pairs(a) do
		if not BrainDoc.programsEqual(a[k], b[k]) then return false end
		na = na + 1
	end
	for _ in pairs(b) do nb = nb + 1 end
	return na == nb
end

return BrainDoc
