--!strict
-- TileProgram.luau — the tile-program data model + Phase 1 STARTER brains.
-- Ported from src/maker/TileProgram.js. A tile program is pure data; behavior
-- lives in Systems/BrainVM.luau (the VM). The full editor GUI is Phase 2+ —
-- Phase 1 loads pre-built programs (the original example programs, verbatim
-- trees) as the "starter brain".
--
-- NODE TYPES (Phase 1 VM subset):
--   action        { type='action', prim, params }   drive | turn | beep | led
--   wait          { type='wait', seconds }
--   forever       { type='forever', body }
--   if_else       { type='if_else', cond, body, elseBody }
-- CONDITION: { sensor, cmp, value }   cmp ∈ lt|gt|lte|gte|eq|neq|is
-- SENSORS (Phase 1): distance_ahead  (0..1, normalized vs SONAR_RANGE)

local TileProgram = {}

TileProgram.T = {
	action = function(prim: string, params: {[string]: any}?)
		return { type = "action", prim = prim, params = params or {} }
	end,
	wait = function(seconds: number)
		return { type = "wait", seconds = math.max(0, seconds) }
	end,
	forever = function(body: { any })
		return { type = "forever", body = body }
	end,
	ifElse = function(cond: {[string]: any}, body: { any }, elseBody: { any })
		return { type = "if_else", cond = cond, body = body, elseBody = elseBody }
	end,
	cond = function(sensor: string, cmp: string, value: number)
		return { sensor = sensor, cmp = cmp, value = value }
	end,
}

-- STARTER BRAIN 1 — "Wall Avoider"
-- VERBATIM port of TileProgram.js EXAMPLE_WALL_AVOIDER:
--   forever [ ifElse (distance_ahead lt 0.25)
--               [ beep high, turn right 0.6, wait 0.4 ]
--               [ drive forward 0.6 ] ]
TileProgram.STARTER_WALL_AVOIDER = {
	name = "Wall Avoider",
	brain = "tin",
	nodes = {
		TileProgram.T.forever({
			TileProgram.T.ifElse(
				TileProgram.T.cond("distance_ahead", "lt", 0.25),
				{
					TileProgram.T.action("beep", { pitch = "high" }),
					TileProgram.T.action("turn", { dir = "right", speed = 0.6 }),
					TileProgram.T.wait(0.4),
				},
				{
					TileProgram.T.action("drive", { dir = "forward", speed = 0.6 }),
				}
			),
		}),
	},
}

-- STARTER BRAIN 2 — "Oval Circler" (Phase-1 bonus; same tile vocabulary,
-- tuned to SONAR_RANGE so the bot keeps the oval's inner wall on its left)
TileProgram.STARTER_OVAL_CIRCLER = {
	name = "Oval Circler",
	brain = "tin",
	nodes = {
		TileProgram.T.forever({
			TileProgram.T.ifElse(
				TileProgram.T.cond("distance_ahead", "lt", 0.55),
				{
					TileProgram.T.action("turn", { dir = "left", speed = 0.5 }),
					TileProgram.T.wait(0.12),
				},
				{
					TileProgram.T.action("drive", { dir = "forward", speed = 0.5 }),
				}
			),
		}),
	},
}

return TileProgram
