--!strict
-- Items.luau — item definitions. EXTRACTED subset from src/data/items.js
-- (names / icons / stack sizes verbatim for everything the MVP loop touches).

local Items = {}

-- category: material | tool | module | brain
Items.DEF = {
	-- ── Raw scrap ──
	iron_scrap     = { name = "Iron Scrap",    icon = "🔩", stack = 64, category = "material" },
	copper_wire    = { name = "Copper Wire",   icon = "🪢", stack = 64, category = "material" },
	rubber_chunk   = { name = "Rubber Chunk",  icon = "⬛", stack = 32, category = "material" },
	gear_small     = { name = "Small Gear",    icon = "⚙️", stack = 32, category = "material" },
	circuit_board  = { name = "Circuit Board", icon = "🟢", stack = 16, category = "material" },
	fuel_can       = { name = "Fuel Can",      icon = "🛢️", stack = 16, category = "material" },
	wood_plank     = { name = "Wood Plank",    icon = "🪵", stack = 32, category = "material" },
	glass_shard    = { name = "Glass Shard",   icon = "💎", stack = 32, category = "material" },
	spring         = { name = "Spring",        icon = "🌀", stack = 32, category = "material" },
	battery_dead   = { name = "Dead Battery",  icon = "🔋", stack = 16, category = "material" },
	track_strip    = { name = "Track Strip",   icon = "▬", stack = 64, category = "material" },

	-- ── Tools (MVP chain) ──
	wrench         = { name = "Wrench",        icon = "🔧", stack = 1,  category = "tool" },
	pliers         = { name = "Pliers",        icon = "🧰", stack = 1,  category = "tool" },

	-- ── Maker modules + brains ──
	ultrasonic_module = { name = "Ultrasonic Module", icon = "📡", stack = 4, category = "module" },
	tin_brain      = { name = "Tin Brain",     icon = "🧠", stack = 4,  category = "brain",
		desc = "A tiny brain for a tiny robot." },

	-- Lucky-loot entries that can appear before their craft systems exist
	battery_pack   = { name = "Battery Pack",  icon = "🔋", stack = 8,  category = "material" },
	ir_module      = { name = "IR Module",     icon = "🔴", stack = 8,  category = "module" },
	ldr_module     = { name = "LDR Module",    icon = "🔆", stack = 8,  category = "module" },
	crystal_fragment = { name = "Crystal Fragment", icon = "🔮", stack = 16, category = "material" },
}

function Items.get(id: string)
	return Items.DEF[id]
end

return Items
