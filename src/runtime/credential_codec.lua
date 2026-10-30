-- Reversible credential packaging, not encryption. The checksum detects
-- accidental corruption; another script can decode or replace this data.
return function(env)
	local util = env.require("runtime/util")
	local M = { maxBytes = 2 * 1024 * 1024,
		error = "Saved credential data is unreadable or uses an unsupported version." }
	local MODULUS = 4294967296
	local function integer(value, maximum)
		return type(value) == "number" and value == value and value >= 0 and value <= maximum and value % 1 == 0
	end
	local function mask(index) return (83 + (index - 1) * 37) % 256 end
	function M.encode(value)
		if type(value) ~= "table" then return nil, M.error end
		local ok, body = pcall(util.encode, value)
		if not ok or type(body) ~= "string" or #body == 0 or #body > M.maxBytes then return nil, M.error end
		local data, checksum = {}, 0
		for index = 1, #body do
			local byte = string.byte(body, index)
			data[index] = (byte + mask(index)) % 256
			checksum = (checksum * 131 + byte) % MODULUS
		end
		return { version = 1, encoding = "uai-bytes-v1", data = data, checksum = checksum }
	end
	function M.decode(envelope)
		if type(envelope) ~= "table" or envelope.version ~= 1 or envelope.encoding ~= "uai-bytes-v1"
			or type(envelope.data) ~= "table" or not integer(envelope.checksum, MODULUS - 1) then return nil, M.error end
		local length, count = #envelope.data, 0
		if length == 0 or length > M.maxBytes then return nil, M.error end
		for index, value in pairs(envelope.data) do
			if not integer(index, length) or index < 1 or not integer(value, 255) then return nil, M.error end
			count = count + 1
		end
		if count ~= length then return nil, M.error end
		local chunks, checksum = {}, 0
		for index = 1, length do
			local byte = (envelope.data[index] - mask(index)) % 256
			chunks[index] = string.char(byte)
			checksum = (checksum * 131 + byte) % MODULUS
		end
		if checksum ~= envelope.checksum then return nil, M.error end
		local decoded = util.decode(table.concat(chunks))
		if type(decoded) ~= "table" then return nil, M.error end
		return decoded
	end
	return M
end
