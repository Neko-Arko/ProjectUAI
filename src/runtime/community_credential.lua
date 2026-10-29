-- Reversible byte encoding avoids plain string copies in distributed files.
-- This is not encryption: scripts in the runtime can extract the credential.
-- Only intentionally distributed community access belongs in this module.
return function(env)
	local function decode(bytes)
		local out = {}
		for index, value in ipairs(bytes) do
			out[index] = string.char((value - ((83 + (index - 1) * 37) % 256)) % 256)
		end
		return table.concat(out)
	end
	local M = { key = decode({ 198, 227, 202, 3, 30, 115, 154, 140, 199, 217, 58, 83, 90, 106, 198, 228, 8, 18, 34, 71, 108, 199, 245, 18, 253, 72, 96, 141, 148, 212, 237, 54, 94, 113, 129, 201, 1, 15, 20, 63, 141, 116, 222, 228, 255, 67, 95, 134, 152, 191, 213 }) }
	local retired = { decode({ 198, 227, 202, 59, 90, 97, 146, 170, 234, 24, 58, 50, 127, 137, 210, 197, 229, 59, 94, 138, 154, 190, 195, 20, 48, 40, 141, 113, 212, 184, 250, 64, 42, 100, 115, 217, 200, 15, 61, 72, 92, 135, 151, 224, 36, 60, 70, 79, 175, 221, 230 }) }
	function M.isRetired(value)
		if type(value) ~= "string" then return false end
		for _, previous in ipairs(retired) do if value == previous then return true end end
		return false
	end
	M.revision = "2026-10-29"
	return M
end
