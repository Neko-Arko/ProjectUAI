-- Published primitive vectors and adversarial vault cryptography checks.
-- Sources: FIPS 197 appendix C; FIPS 180-4; RFC 4231 section 4;
-- RFC 4493 section 4; RFC 5297 appendix A; RFC 7914 section 11.
-- Only synthetic keys/passwords. No executor crypto, RNG, network or filesystem.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Credential cryptography")
local case, check = suite.case, suite.check
local function unhex(text)
	text = text:gsub("%s", "")
	assert(#text % 2 == 0 and not text:find("[^0-9a-fA-F]"), "invalid hex fixture")
	return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end
local function hex(text)
	return (text:gsub(".", function(value) return string.format("%02x", string.byte(value)) end))
end

case("hosts without bit32 fail closed without plaintext fallbacks", function()
	local f = F.new(); f.h.sandbox.bit32 = nil
	local crypto = f.env.require("runtime/credential_crypto")
	local key = string.rep("x", 64)
	check("missing primitives cannot encrypt or decrypt", crypto.seal(key, "synthetic private data", {}) == nil
		and crypto.open(key, string.rep("x", 32), {}) == nil)
	check("missing primitives cannot derive or authenticate", crypto.derive("synthetic password", "salt", 1) == nil
		and crypto.cmac(key:sub(1, 32), "synthetic private data") == nil)
	f.healthy(); f.close()
end)

case("AES matches FIPS 197 for all three block-key lengths", function()
	local f = F.new(); local aes = f.env.require("runtime/credential_aes")
	for _, vector in ipairs({
		{ "000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a" },
		{ "000102030405060708090a0b0c0d0e0f1011121314151617", "dda97ca4864cdfe06eaf70a0ec0d7191" },
		{ "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "8ea2b7ca516745bfeafc49904b496089" },
	}) do
		local cipher = assert(aes.new(unhex(vector[1])))
		check("FIPS AES vector", hex(cipher.encrypt(unhex("00112233445566778899aabbccddeeff"))) == vector[2])
		check("AES rejects partial blocks", cipher.encrypt("short") == nil)
	end
	check("AES rejects unsupported key lengths", aes.new(string.rep("x", 17)) == nil)
	f.healthy(); f.close()
end)

case("SHA256 and HMAC match published known answers", function()
	local f = F.new(); local sha = f.env.require("runtime/credential_sha256")
	for _, vector in ipairs({
		{ "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
		{ "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
		{ "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
	}) do check("published SHA256 vector", hex(sha.digest(vector[1])) == vector[2]) end
	check("RFC 4231 HMAC case 1", hex(sha.hmac(string.rep("\11", 20), "Hi There")) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
	check("RFC 4231 HMAC case 2", hex(sha.hmac("Jefe", "what do ya want for nothing?")) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
	check("RFC 4231 long HMAC key", hex(sha.hmac(string.rep("\170", 131), "Test Using Larger Than Block-Size Key - Hash Key First"))
		== "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
	f.healthy(); f.close()
end)

case("CMAC matches RFC 4493 at empty, complete and partial blocks", function()
	local f = F.new(); local crypto = f.env.require("runtime/credential_crypto")
	local key = unhex("2b7e151628aed2a6abf7158809cf4f3c")
	local message = unhex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
		.. "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
	for _, vector in ipairs({ { 0, "bb1d6929e95937287fa37d129b756746" }, { 16, "070a16b46b4d4144f79bdd9dd04a287c" },
		{ 40, "dfa66747de9ae63030ca32611497c827" }, { 64, "51f0bebf7e3b9d92fc49741779363cfe" } }) do
		check("RFC CMAC vector", hex(crypto.cmac(key, message:sub(1, vector[1]))) == vector[2])
	end
	f.healthy(); f.close()
end)

case("PBKDF2 derives both key halves from RFC 7914 vectors", function()
	local f = F.new(); local crypto = f.env.require("runtime/credential_crypto")
	check("one-iteration PBKDF2 vector", hex(crypto.derive("passwd", "salt", 1))
		== "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
	local last, reports = -1, 0
	local key = crypto.derive("Password", "NaCl", 80000, function(completed, total)
		assert(completed >= last and completed <= total and total == 160000)
		last, reports = completed, reports + 1
	end)
	check("80000-iteration PBKDF2 vector", hex(key)
		== "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
	check("derivation exposes bounded progress and completion", last == 160000 and reports > 1200 and reports < 1300)
	f.healthy(); f.close()
end)

case("derivation cancels safely and rejects invalid work parameters", function()
	local f = F.new(); local crypto = f.env.require("runtime/credential_crypto")
	local last = -1
	local key, why = crypto.derive("fixture password", "public salt", 2000, function(completed)
		last = completed; return completed == 0
	end)
	check("cancellation releases no partial key", key == nil and why == crypto.error and last == 128)
	key, why = crypto.derive("fixture password", "public salt", 2, function() error("private callback detail") end)
	check("callback failures disclose no password or callback detail", key == nil and why == crypto.error)
	for _, iterations in ipairs({ 0, -1, 1.5, 2000001, math.huge, 0 / 0 }) do
		check("invalid iteration counts fail before work", crypto.derive("password", "salt", iterations) == nil)
	end
	check("oversized passwords and salts fail before work", crypto.derive(string.rep("x", 1025), "salt", 1) == nil
		and crypto.derive("password", string.rep("x", 1025), 1) == nil)
	f.healthy(); f.close()
end)

case("SIV matches both complete RFC 5297 examples", function()
	local f = F.new(); local crypto = f.env.require("runtime/credential_crypto")
	local vectors = {
		{ key = "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
			aad = { "101112131415161718191a1b1c1d1e1f2021222324252627" },
			plain = "112233445566778899aabbccddee",
			sealed = "85632d07c6e8f37f950acd320a2ecc9340c02b9690c4dc04daef7f6afe5c" },
		{ key = "7f7e7d7c7b7a79787776757473727170404142434445464748494a4b4c4d4e4f",
			aad = { "00112233445566778899aabbccddeeffdeaddadadeaddadaffeeddccbbaa99887766554433221100",
				"102030405060708090a0", "09f911029d74e35bd84156c5635688c0" },
			plain = "7468697320697320736f6d6520706c61696e7465787420746f20656e6372797074207573696e67205349562d414553",
			sealed = "7bdb6e3b432667eb06f4d14bff2fbd0fcb900f2fddbe404326601965c889bf17dba77ceb094fa663b7a3f748ba8af829ea64ad544a272e9c485b62a3fd5c0d" },
	}
	for _, vector in ipairs(vectors) do
		local aad = {}; for index, item in ipairs(vector.aad) do aad[index] = unhex(item) end
		check("RFC SIV ciphertext and tag", hex(crypto.seal(unhex(vector.key), unhex(vector.plain), aad)) == vector.sealed)
		check("RFC SIV authenticated decryption", hex(crypto.open(unhex(vector.key), unhex(vector.sealed), aad)) == vector.plain)
	end
	f.healthy(); f.close()
end)

case("AES256 SIV protects binary boundaries, key identity and separate AAD fields", function()
	local f = F.new(); local crypto = f.env.require("runtime/credential_crypto")
	local key, other = string.rep("\7", 64), string.rep("\8", 64)
	local bytes = {}; for value = 0, 255 do bytes[#bytes + 1] = string.char(value) end
	local binary = table.concat(bytes):rep(20)
	for _, length in ipairs({ 0, 1, 15, 16, 17, 31, 32, 33, 255, 256, 257, 4097 }) do
		local plain = binary:sub(1, length)
		local sealed = assert(crypto.seal(key, plain, { "provider", "id", "" }))
		check("binary plaintext authenticates across block boundaries", #sealed == #plain + 16 and crypto.open(key, sealed, { "provider", "id", "" }) == plain)
		check("deterministic re-encryption is stable", crypto.seal(key, plain, { "provider", "id", "" }) == sealed)
		check("wrong keys and reordered metadata cannot decrypt", crypto.open(other, sealed, { "provider", "id", "" }) == nil
			and crypto.open(key, sealed, { "id", "provider", "" }) == nil)
	end
	local sealed = assert(crypto.seal(key, "private fixture credential", { "ab", "c" }))
	check("AAD boundaries are authenticated", crypto.open(key, sealed, { "a", "bc" }) == nil)
	check("absent and empty AAD fields remain distinct", crypto.seal(key, "", {}) ~= crypto.seal(key, "", { "" }))
	for offset = 1, #sealed do
		local damaged = sealed:sub(1, offset - 1) .. string.char((string.byte(sealed, offset) + 1) % 256) .. sealed:sub(offset + 1)
		local plain, why = crypto.open(key, damaged, { "ab", "c" })
		check("every modified tag or ciphertext byte fails without plaintext", plain == nil and why == crypto.error)
	end
	check("truncated ciphertext cannot decrypt", crypto.open(key, sealed:sub(1, -2), { "ab", "c" }) == nil)
	check("invalid AAD vectors cannot be silently reinterpreted", crypto.seal(key, "", { [2] = "gap" }) == nil
		and crypto.seal(key, "", { extra = "map" }) == nil and crypto.seal(key, "", { false }) == nil)
	local aad = {}; for index = 1, 127 do aad[index] = "" end
	check("the RFC vector bound is enforced", crypto.seal(key, "", aad) == nil)
	check("oversized messages and metadata fail before encryption", crypto.seal(key, string.rep("x", crypto.maxBytes + 1), {}) == nil
		and crypto.seal(key, "", { string.rep("x", crypto.maxBytes + 1) }) == nil)
	f.healthy(); f.close()
end)

suite.finish()
