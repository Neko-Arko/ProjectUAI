-- AES block encryption from FIPS 197 (2023), sections 5.1 and 5.2.
-- https://doi.org/10.6028/NIST.FIPS.197-upd1
-- Forward encryption only: RFC 5297 uses AES-CMAC and AES-CTR. This module
-- implements the standard directly; it is not a substitute for independent
-- cryptographic review. Table lookups do not promise constant-time execution.
return function(env)
	local M = { error = "Credential encryption is unavailable or received invalid data." }
	local bits = bit32
	if type(bits) ~= "table" or type(bits.band) ~= "function" or type(bits.bxor) ~= "function"
		or type(bits.lshift) ~= "function" or type(bits.rshift) ~= "function" or type(bits.rrotate) ~= "function" then
		function M.new() return nil, M.error end
		return M
	end
	local band, bxor, lshift, rshift, rrotate = bits.band, bits.bxor, bits.lshift, bits.rshift, bits.rrotate
	local byte, char = string.byte, string.char
	-- FIPS 197, Table 4. Zero-based indices are byte values.
	local S = {
		[0] = 0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
		0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
		0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
		0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
		0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
		0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
		0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
		0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
		0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
		0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
		0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
		0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
		0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
		0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
		0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
		0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
	}
	local T0, T1, T2, T3 = {}, {}, {}, {}
	for index = 0, 255 do
		local value = S[index]
		local twice = value < 128 and value * 2 or bxor(value * 2, 0x11b)
		-- One substituted column contribution: [2*s, s, s, 3*s].
		local word = lshift(twice, 24) + lshift(value, 16) + lshift(value, 8) + bxor(twice, value)
		T0[index], T1[index], T2[index], T3[index] = word, rrotate(word, 8), rrotate(word, 16), rrotate(word, 24)
	end
	local function wordAt(text, offset)
		local a, b, c, d = byte(text, offset, offset + 3)
		return a * 16777216 + b * 65536 + c * 256 + d
	end
	local function wordBytes(word)
		return char(rshift(word, 24), band(rshift(word, 16), 255), band(rshift(word, 8), 255), band(word, 255))
	end
	local function substitute(word)
		return lshift(S[rshift(word, 24)], 24) + lshift(S[band(rshift(word, 16), 255)], 16)
			+ lshift(S[band(rshift(word, 8), 255)], 8) + S[band(word, 255)]
	end
	function M.new(key)
		if type(key) ~= "string" or (#key ~= 16 and #key ~= 24 and #key ~= 32) then return nil, M.error end
		local nk, rounds = #key / 4, #key / 4 + 6
		local words = {}
		for index = 0, nk - 1 do words[index] = wordAt(key, index * 4 + 1) end
		local roundConstant = 1
		for index = nk, (rounds + 1) * 4 - 1 do
			local previous = words[index - 1]
			if index % nk == 0 then
				previous = bxor(substitute(rrotate(previous, 24)), lshift(roundConstant, 24))
				roundConstant = roundConstant < 128 and roundConstant * 2 or bxor(roundConstant * 2, 0x11b)
			elseif nk == 8 and index % nk == 4 then previous = substitute(previous) end
			words[index] = bxor(words[index - nk], previous)
		end
		local cipher = {}
		function cipher.encrypt(block)
			if type(block) ~= "string" or #block ~= 16 then return nil, M.error end
			local a = bxor(wordAt(block, 1), words[0])
			local b = bxor(wordAt(block, 5), words[1])
			local c = bxor(wordAt(block, 9), words[2])
			local d = bxor(wordAt(block, 13), words[3])
			for round = 1, rounds - 1 do
				local offset = round * 4
				local nextA = bxor(T0[rshift(a, 24)], T1[band(rshift(b, 16), 255)], T2[band(rshift(c, 8), 255)], T3[band(d, 255)], words[offset])
				local nextB = bxor(T0[rshift(b, 24)], T1[band(rshift(c, 16), 255)], T2[band(rshift(d, 8), 255)], T3[band(a, 255)], words[offset + 1])
				local nextC = bxor(T0[rshift(c, 24)], T1[band(rshift(d, 16), 255)], T2[band(rshift(a, 8), 255)], T3[band(b, 255)], words[offset + 2])
				local nextD = bxor(T0[rshift(d, 24)], T1[band(rshift(a, 16), 255)], T2[band(rshift(b, 8), 255)], T3[band(c, 255)], words[offset + 3])
				a, b, c, d = nextA, nextB, nextC, nextD
			end
			-- The final round applies SubBytes and ShiftRows without MixColumns.
			local last = rounds * 4
			local outA = bxor(lshift(S[rshift(a, 24)], 24) + lshift(S[band(rshift(b, 16), 255)], 16)
				+ lshift(S[band(rshift(c, 8), 255)], 8) + S[band(d, 255)], words[last])
			local outB = bxor(lshift(S[rshift(b, 24)], 24) + lshift(S[band(rshift(c, 16), 255)], 16)
				+ lshift(S[band(rshift(d, 8), 255)], 8) + S[band(a, 255)], words[last + 1])
			local outC = bxor(lshift(S[rshift(c, 24)], 24) + lshift(S[band(rshift(d, 16), 255)], 16)
				+ lshift(S[band(rshift(a, 8), 255)], 8) + S[band(b, 255)], words[last + 2])
			local outD = bxor(lshift(S[rshift(d, 24)], 24) + lshift(S[band(rshift(a, 16), 255)], 16)
				+ lshift(S[band(rshift(b, 8), 255)], 8) + S[band(c, 255)], words[last + 3])
			return wordBytes(outA) .. wordBytes(outB) .. wordBytes(outC) .. wordBytes(outD)
		end
		return cipher
	end
	return M
end
