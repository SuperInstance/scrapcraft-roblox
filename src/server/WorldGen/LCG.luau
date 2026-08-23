--!strict
-- LCG.luau — seeded linear congruential generator.
-- BIT-EXACT port of World.js:
--   function lcg(seed) {
--     let s = seed >>> 0;
--     return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 0xffffffff; };
--   }
--
-- Precision argument (why plain doubles are exact here):
--   s < 2^32, so s * 1664525 <= (2^32-1)*1664525 ≈ 7.15e15 < 2^53 ≈ 9.007e15.
--   The multiply, the add, and the % 2^32 are therefore exact in IEEE doubles.
--   (A generic 32x32 multiply would NOT be safe; this multiplier is.)

local LCG = {}
LCG.__index = LCG

local MODULUS = 4294967296      -- 2^32
local DIVISOR = 4294967295      -- 0xffffffff (the original divides by this, not 2^32)

export type LCG_t = typeof(setmetatable({} :: { _s: number }, LCG))

function LCG.new(seed: number): LCG_t
	return setmetatable({ _s = math.floor(seed) % MODULUS }, LCG)
end

-- Next float in [0, 1) — consumes one step, like the original closure.
function LCG.next(self: LCG_t): number
	self._s = (self._s * 1664525 + 1013904223) % MODULUS
	return self._s / DIVISOR
end

-- Convenience helpers matching call sites in World.js:
--   Math.floor(rng() * n)
function LCG.nextInt(self: LCG_t, n: number): number
	return math.floor(self:next() * n)
end

-- In-range integer [lo, lo + span) where the original wrote
--   lo + Math.floor(rng() * span)
function LCG.rangeInt(self: LCG_t, lo: number, span: number): number
	return lo + math.floor(self:next() * span)
end

return LCG
