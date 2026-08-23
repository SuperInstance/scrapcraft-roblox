--!strict
-- Blocks.luau — block registry. EXTRACTED from src/data/blocks.js verbatim.
-- color = hex from BLOCK_DEF; hardness = seconds to mine (hold);
-- drop/altDrop = item ids with real dropChances.

local Blocks = {}

-- B enum — ids identical to the original export const B
Blocks.B = {
	AIR = 0,
	DIRT = 1,
	GRAVEL = 2,
	CONCRETE = 3,
	RUST_METAL = 4,
	CLEAN_METAL = 5,
	WOOD_PLANK = 6,
	SCRAP_PILE = 7,
	WORKBENCH = 8,
	FORGE = 9,
	SMELTER = 10,
	OIL_DRUM = 11,
	CRATE = 12,
	WALL_METAL = 13,
	ROOF_METAL = 14,
	JUNK_CAR = 15,
	POWER_BOX = 16,
	TRACK = 17,
	FLOODLIGHT = 18,
	CRYSTAL_ORE = 19,
	SCRAP_CANNON = 20,
	ACID_PUDDLE = 21,
	BURIED_CACHE = 22,
	HOT_SLAG = 23,
	SOLAR_PANEL = 24,
	BEACON = 25,
}

local B = Blocks.B

-- BLOCK_DEF (colors are hex, exactly the original)
-- hardness nil = not mineable in Phase 1 (interactive stations / structures)
Blocks.DEF = {
	[B.DIRT] =        { name = "Compacted Dirt",  color = 0x7a5c3a, hardness = 0.3 },
	[B.GRAVEL] =      { name = "Gravel",          color = 0x6e6e6e, hardness = 0.3 },
	[B.CONCRETE] =    { name = "Cracked Concrete", color = 0x888880, hardness = 0.7 },
	[B.RUST_METAL] =  { name = "Rusted Metal",   color = 0x8B3A00, hardness = 0.45,
		drop = "iron_scrap", dropChance = 1.0 },
	[B.CLEAN_METAL] = { name = "Steel Panel",    color = 0x9fb5c0, hardness = 0.85,
		drop = "iron_scrap", dropChance = 0.7 },
	[B.WOOD_PLANK] =  { name = "Rotted Wood",    color = 0x6b4c27, hardness = 0.35,
		drop = "wood_plank", dropChance = 1.0 },
	[B.SCRAP_PILE] =  { name = "Scrap Pile",     color = 0x5a5a4a, hardness = 0.4,
		drop = "iron_scrap", dropChance = 0.8,
		altDrop = "gear_small", altDropChance = 0.35 },
	[B.WORKBENCH] =   { name = "Workbench",      color = 0xb5832a, interactive = true, station = "workbench",
		emissive = 0x261a00 },
	[B.FORGE] =       { name = "Forge",          color = 0x444444, interactive = true, station = "forge",
		emissive = 0xff4400 },
	[B.SMELTER] =     { name = "Smelter",        color = 0x555533, interactive = true, station = "smelter",
		emissive = 0xff8800 },
	[B.OIL_DRUM] =    { name = "Oil Drum",       color = 0x1a1a8a, hardness = 0.55,
		drop = "fuel_can", dropChance = 0.9 },
	[B.CRATE] =       { name = "Mystery Crate",  color = 0x8b6020, hardness = 0.38,
		drop = "circuit_board", dropChance = 0.5,
		altDrop = "copper_wire", altDropChance = 0.8 },
	[B.WALL_METAL] =  { name = "Metal Wall",     color = 0x707070, hardness = 0.95 },
	[B.ROOF_METAL] =  { name = "Corrugated Roof", color = 0x607060, hardness = 0.95 },
	[B.JUNK_CAR] =    { name = "Junk Car",       color = 0x3a3a2a, hardness = 1.1,
		drop = "rubber_chunk", dropChance = 1.0,
		altDrop = "gear_small", altDropChance = 0.6 },
	[B.POWER_BOX] =   { name = "Power Box",      color = 0xddcc00, hardness = 0.6,
		drop = "copper_wire", dropChance = 1.0,
		altDrop = "circuit_board", altDropChance = 0.4 },
	[B.TRACK] =       { name = "Track Strip",    color = 0x222211, hardness = 0.25,
		emissive = 0xddcc00,
		drop = "track_strip", dropChance = 1.0 },
	[B.FLOODLIGHT] =  { name = "Floodlight",     color = 0xeeeebb, hardness = 0.5,
		emissive = 0xffffff,
		drop = "floodlight", dropChance = 1.0 },
	[B.CRYSTAL_ORE] = { name = "Crystal Ore",    color = 0x2a0a5e, hardness = 0.6,
		emissive = 0x9933ff,
		drop = "glass_shard", dropChance = 1.0, dropQty = 3,
		altDrop = "battery_dead", altDropChance = 0.5 },
	[B.SCRAP_CANNON] ={ name = "Scrap Cannon",   color = 0x4a3a2a, interactive = true, station = "scrap_cannon",
		emissive = 0x331100 },
	[B.ACID_PUDDLE] = { name = "Acid Puddle",    color = 0x3a6e0a, nonSolid = true, hazard = "acid", hazardDps = 4,
		drop = "rubber_chunk", dropChance = 0.3 },
	[B.BURIED_CACHE] ={ name = "Buried Cache",   color = 0x1a4455, emissive = 0x005577 },
	[B.HOT_SLAG] =    { name = "Hot Slag",       color = 0xcc3300, nonSolid = true, hazard = "fire", hazardDps = 5,
		drop = "iron_scrap", dropChance = 0.6 },
	[B.SOLAR_PANEL] = { name = "Solar Panel",    color = 0x2244aa, hardness = 0.8,
		drop = "solar_panel", dropChance = 1.0 },
	[B.BEACON] =      { name = "Signal Beacon",  color = 0x004444, hardness = 0.5,
		emissive = 0x00ffcc,
		drop = "signal_beacon", dropChance = 1.0 },
}

-- Game.js L1211–1212 — lucky find sets, verbatim
Blocks.LUCKY_BLOCKS = {
	[B.SCRAP_PILE] = true,
	[B.OIL_DRUM] = true,
	[B.JUNK_CAR] = true,
}
Blocks.LUCKY_LOOT = {
	"battery_pack", "ir_module", "circuit_board", "ldr_module",
	"spring", "gear_small", "crystal_fragment",
}

function Blocks.isMineable(id: number): boolean
	local def = Blocks.DEF[id]
	return def ~= nil and def.hardness ~= nil and not def.interactive
end

function Blocks.isSolid(id: number): boolean
	-- blocks.js isSolid: AIR false; hazard puddles nonSolid false
	if id == B.AIR then return false end
	local def = Blocks.DEF[id]
	if def == nil then return false end
	return not def.nonSolid
end

return Blocks
