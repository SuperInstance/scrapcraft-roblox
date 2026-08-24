--!strict
-- Recipes.luau — crafting recipes. EXTRACTED from src/data/recipes.js.
-- Phase 1 ships the MVP chain (wrench → pliers → ultrasonic module → tin
-- brain) plus a couple of real tier-1s. Ingredient counts, station, tool and
-- tier are verbatim from the original. Full recipe book lands with Phase 2.

local Recipes = {}

Recipes.LIST = {
	-- ── MVP chain ──
	{
		id = "r_wrench",
		output = "wrench", qty = 1,
		ingredients = { iron_scrap = 3, wood_plank = 1 },
		station = "any", tier = 1,
	},
	{
		id = "r_pliers",
		output = "pliers", qty = 1,
		ingredients = { iron_scrap = 2, copper_wire = 1 },
		station = "any", tier = 1,
	},
	{
		id = "r_ultrasonic_module",
		output = "ultrasonic_module", qty = 1,
		ingredients = { circuit_board = 1, copper_wire = 2 },
		station = "workbench", tier = 1,
	},
	{
		id = "r_tin_brain",
		output = "tin_brain", qty = 1,
		ingredients = { circuit_board = 2, copper_wire = 4, iron_scrap = 3 },
		station = "workbench", tool = "pliers", tier = 1,
		quip = "A tiny brain for a tiny robot. Don't take that personally. It's actually impressive.",
	},

	-- ── Real tier-1 extras (same numbers as the original) ──
	{
		id = "r_hammer",
		output = "hammer", qty = 1,   -- item def arrives with the tooling phase; harmless stub
		ingredients = { iron_scrap = 2, wood_plank = 2 },
		station = "any", tier = 1,
	},
	{
		id = "r_silly_hat",
		output = "silly_hat", qty = 1,
		ingredients = { scrap_candy = 3 },
		station = "workbench", tier = 1,
		quip = "Wrappers and sugar bolts. Wear it at the races. Earl pretends to hate it.",
		},
{
		id = "r_track_strip",

		output = "track_strip", qty = 8,
		ingredients = { rubber_chunk = 2, iron_scrap = 1 },
		station = "workbench", tier = 1,
		quip = "A track for your robot. Build a course. Bet on it. I'm not saying anything else.",
	},
}

function Recipes.get(id: string)
	for _, r in ipairs(Recipes.LIST) do
		if r.id == id then return r end
	end
	return nil
end

-- Recipes craftable at a given station ('workbench' | 'forge' | 'smelter');
-- station 'any' always qualifies. — recipes.js getRecipesForStation
function Recipes.forStation(station: string)
	local out = {}
	for _, r in ipairs(Recipes.LIST) do
		if r.station == "any" or r.station == station then
			table.insert(out, r)
		end
	end
	return out
end

return Recipes
