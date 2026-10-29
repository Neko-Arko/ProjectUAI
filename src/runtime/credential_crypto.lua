-- Password-vault cryptography: RFC 5297 AES-SIV, with CMAC from NIST SP 800-38B.
-- SIV authenticates deterministic encryption without requiring a random nonce.
-- Equal plaintext and associated data under one key reveal equality. These
-- managed-language primitives do not promise constant-time execution or erasure.
return function(env)
	local aes = env.require("runtime/credential_aes")
	local sha = env.require("runtime/credential_sha256")
	local M = { error = "Credential cryptography failed.", maxBytes = 2 * 1024 * 1024 }
	if type(bit32) ~= "table" or type(bit32.band) ~= "function" or type(bit32.bxor) ~= "function" then
		function M.cmac() return nil, M.error end
		function M.derive() return nil, M.error end
		function M.seal() return nil, M.error end
		function M.open() return nil, M.error end
		return M
	end
	local band, bxor = bit32.band, bit32.bxor
	local byte, char, concat = string.byte, string.char, table.concat
	local ZERO = string.rep("\0", 16)
	local function xor(left, right)
		local out = {}
		for index = 1, #left do out[index] = char(bxor(byte(left, index), byte(right, index))) end
		return concat(out)
	end
	local function double(block)
		local out, carry = {}, 0
		for index = 16, 1, -1 do
			local value = byte(block, index)
			out[index], carry = char((value * 2 + carry) % 256), math.floor(value / 128)
		end
		if carry ~= 0 then out[16] = char(bxor(byte(out[16]), 0x87)) end
		return concat(out)
	end
	local function padded(text)
		return text .. "\128" .. string.rep("\0", 15 - #text)
	end
	local function macContext(cipher)
		local first = double(cipher.encrypt(ZERO))
		return { cipher = cipher, first = first, second = double(first) }
	end
	local function cmac(context, text)
		local blocks = math.max(1, math.ceil(#text / 16))
		local state = ZERO
		for index = 1, blocks - 1 do state = context.cipher.encrypt(xor(state, text:sub((index - 1) * 16 + 1, index * 16))) end
		local tail = text:sub((blocks - 1) * 16 + 1)
		if #tail == 16 then tail = xor(tail, context.first)
		else tail = xor(padded(tail), context.second) end
		return context.cipher.encrypt(xor(state, tail))
	end
	function M.cmac(key, text)
		if type(text) ~= "string" or #text > M.maxBytes then return nil, M.error end
		local cipher = aes.new(key)
		if not cipher then return nil, M.error end
		return cmac(macContext(cipher), text)
	end
	local function associated(aad)
		if aad == nil then return {} end
		if type(aad) ~= "table" or #aad > 126 then return nil end
		local count, total = 0, 0
		for index, value in pairs(aad) do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #aad or type(value) ~= "string" then return nil end
			count, total = count + 1, total + #value
			if total > M.maxBytes then return nil end
		end
		if count ~= #aad then return nil end
		return aad
	end
	local function s2v(context, plaintext, aad)
		local value = cmac(context, ZERO)
		for _, item in ipairs(aad) do value = xor(double(value), cmac(context, item)) end
		if #plaintext >= 16 then
			return cmac(context, plaintext:sub(1, #plaintext - 16) .. xor(plaintext:sub(-16), value))
		end
		return cmac(context, xor(double(value), padded(plaintext)))
	end
	local function contexts(key)
		if type(key) ~= "string" or (#key ~= 32 and #key ~= 48 and #key ~= 64) then return nil end
		local half = #key / 2
		local mac, encryption = aes.new(key:sub(1, half)), aes.new(key:sub(half + 1))
		if not mac or not encryption then return nil end
		return macContext(mac), encryption
	end
	local function ctr(cipher, value, text)
		-- RFC 5297 clears bits 31 and 63 before CTR. With the bounded message
		-- length, the final 32-bit counter cannot overflow.
		local prefix = value:sub(1, 8) .. char(band(byte(value, 9), 0x7f)) .. value:sub(10, 12)
		local counter = ((band(byte(value, 13), 0x7f) * 256 + byte(value, 14)) * 256 + byte(value, 15)) * 256 + byte(value, 16)
		local out = {}
		for offset = 1, #text, 16 do
			local suffix = char(math.floor(counter / 16777216), math.floor(counter / 65536) % 256, math.floor(counter / 256) % 256, counter % 256)
			local stream = cipher.encrypt(prefix .. suffix)
			local chunk = text:sub(offset, offset + 15)
			out[#out + 1] = xor(chunk, stream)
			counter = counter + 1
		end
		return concat(out)
	end
	function M.derive(password, salt, iterations, onProgress)
		return sha.derive64(password, salt, iterations, onProgress)
	end
	function M.seal(key, plaintext, aad)
		if type(plaintext) ~= "string" or #plaintext > M.maxBytes then return nil, M.error end
		aad = associated(aad)
		if not aad then return nil, M.error end
		local mac, cipher = contexts(key)
		if not mac then return nil, M.error end
		local value = s2v(mac, plaintext, aad)
		return value .. ctr(cipher, value, plaintext)
	end
	function M.open(key, sealed, aad)
		if type(sealed) ~= "string" or #sealed < 16 or #sealed > M.maxBytes + 16 then return nil, M.error end
		aad = associated(aad)
		if not aad then return nil, M.error end
		local mac, cipher = contexts(key)
		if not mac then return nil, M.error end
		local value = sealed:sub(1, 16)
		local plaintext = ctr(cipher, value, sealed:sub(17))
		local actual, difference = s2v(mac, plaintext, aad), 0
		for index = 1, 16 do difference = difference + bxor(byte(value, index), byte(actual, index)) end
		if difference ~= 0 then return nil, M.error end
		return plaintext
	end
	return M
end
