-- Roblox's unsigned bit32 interface backed by LuaJIT's signed bit operations.
if type(bit32) == "table" then return bit32 end
local bit = require("bit")
local M = {}
local function unsigned(value) return value < 0 and value + 4294967296 or value end
for _, name in ipairs({ "band", "bor", "bxor", "bnot" }) do
	local operation = bit[name]
	M[name] = function(...) return unsigned(operation(...)) end
end
local function shift(operation, reverse)
	return function(value, amount)
		if amount <= -32 or amount >= 32 then return 0 end
		if amount < 0 then return unsigned(reverse(value, -amount)) end
		return unsigned(operation(value, amount))
	end
end
M.lshift, M.rshift = shift(bit.lshift, bit.rshift), shift(bit.rshift, bit.lshift)
M.lrotate = function(value, amount) return unsigned(bit.rol(value, amount)) end
M.rrotate = function(value, amount) return unsigned(bit.ror(value, amount)) end
return M
