-- Envelope authentication, password policy and private session ownership.
-- Primitive/KDF answers are checked independently in credential_crypto and interop.
-- The derivation adapter below uses synthetic keys to exercise lifecycle races.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Credential vault envelope")
local case, check = suite.case, suite.check
local KEY = string.rep("\19", 64)
local function envelope()
	return { version = 1, cipher = "aes-256-siv", kdf = "pbkdf2-hmac-sha256", iterations = 600000,
		salt = "uai-vault-v1:00000000-0000-4000-8000-000000000001", data = string.rep("0", 32) }
end

case("the envelope rejects malformed and unsupported work before derivation", function()
	local f = F.new(); local vault = f.env.require("runtime/credential_vault")
	check("the supported envelope passes", vault.validate(envelope()))
	for _, pair in ipairs({
		{ "version", 2 }, { "cipher", "aes-256-gcm" }, { "kdf", "other" },
		{ "iterations", 99999 }, { "iterations", 2000001 }, { "iterations", 600000.5 },
		{ "iterations", math.huge }, { "iterations", 0 / 0 }, { "iterations", "600000" },
		{ "salt", "short" }, { "salt", string.rep("a", 129) }, { "salt", string.rep("a", 35) .. "\0" },
		{ "data", string.rep("0", 31) }, { "data", string.rep("0", 33) },
		{ "data", string.rep("g", 32) }, { "data", string.rep("0", (vault.maxBytes + 16) * 2 + 2) },
		{ "unknown", true },
	}) do
		local value = envelope(); value[pair[1]] = pair[2]
		local valid, why = vault.validate(value)
		check("invalid envelope fails without sensitive detail", valid == false and why == vault.error)
	end
	local calls = 0
	f.loaded["runtime/credential_crypto"] = { derive = function() calls = calls + 1; return KEY end }
	local value = envelope(); value.iterations = 1
	check("invalid work cannot invoke derivation", vault.derive("fixture password", value) == nil and calls == 0)
	f.healthy(); f.close()
end)

case("password policy counts UTF8 characters and never trims valid passwords", function()
	local f = F.new(); local vault = f.env.require("runtime/credential_vault")
	check("setup accepts at least twelve characters", vault.passwordValid("twelve chars", true))
	check("short setup and all-whitespace passwords fail", not vault.passwordValid("elevenchars", true)
		and not vault.passwordValid(string.rep(" ", 12), true))
	local emoji = "\240\159\148\144"
	check("twelve Unicode characters pass while eleven fail", vault.passwordValid(emoji:rep(12), true)
		and not vault.passwordValid(emoji:rep(11), true))
	check("unlock accepts existing shorter passwords", vault.passwordValid("short", false))
	check("empty, invalid UTF8 and oversized passwords fail", not vault.passwordValid("", false)
		and not vault.passwordValid("bad\255password", false) and not vault.passwordValid(string.rep("a", 1025), false))
	local password, received = "  exact fixture phrase  ", nil
	f.loaded["runtime/credential_crypto"] = { derive = function(actual, salt, iterations, progress)
		received = actual
		check("the full configured work factor reaches the primitive", salt == envelope().salt and iterations == 600000)
		assert(progress(0, 1200000)); assert(progress(1200000, 1200000)); return KEY
	end }
	check("derivation preserves surrounding spaces", vault.derive(password, envelope()) == KEY and received == password)
	f.healthy(); f.close()
end)

case("authenticated payloads reject changed headers, data and keys", function()
	local f = F.new(); local vault, util = f.env.require("runtime/credential_vault"), f.env.require("runtime/util")
	local payload = { version = 1, providers = { { id = "fixture", apiKey = "synthetic-api-secret", paused = { true, false } } },
		identity = { Authorization = "Bearer synthetic-identity-secret" } }
	local original = envelope()
	local sealed = assert(vault.seal(original, KEY, payload))
	local restored = assert(vault.open(sealed, KEY))
	check("sealing leaves the template unchanged", original.data == string.rep("0", 32) and sealed ~= original)
	check("decrypted nested values survive exactly", restored.providers[1].apiKey == payload.providers[1].apiKey
		and restored.providers[1].paused[1] and not restored.providers[1].paused[2]
		and restored.identity.Authorization == payload.identity.Authorization)
	check("the saved envelope contains neither plaintext nor session key", not util.encode(sealed):find("synthetic-api-secret", 1, true)
		and not util.encode(sealed):find("synthetic-identity-secret", 1, true) and not util.encode(sealed):find(KEY, 1, true))
	for _, change in ipairs({
		function(value) value.salt = value.salt:sub(1, -2) .. "2" end,
		function(value) value.iterations = value.iterations + 1 end,
		function(value) value.data = (value.data:sub(1, 1) == "0" and "1" or "0") .. value.data:sub(2) end,
		function(value) value.data = value.data:sub(1, -3) end,
	}) do
		local changed = util.deepCopy(sealed); change(changed)
		local plain, why = vault.open(changed, KEY)
		check("valid but tampered metadata or ciphertext cannot release payload", plain == nil and why == vault.passwordError)
	end
	local plain, why = vault.open(sealed, string.rep("\20", 64))
	check("wrong passwords have the same authentication error", plain == nil and why == vault.passwordError)
	check("unsupported keys and oversized payloads fail", vault.seal(original, "short", payload) == nil
		and vault.seal(original, KEY, { data = string.rep("x", vault.maxBytes) }) == nil)
	f.healthy(); f.close()
end)

case("session ownership and handoff remain private and are cleared on disposal", function()
	local f = F.new(); local vault = f.env.require("runtime/credential_vault")
	local value = assert(vault.seal(envelope(), KEY, { synthetic = "payload" }))
	check("a new vault owns no session key", vault.key(value) == nil and vault.handoff(value) == nil)
	assert(vault.activate(KEY, value))
	local handoff = assert(vault.handoff(value))
	check("only matching vault headers select the session key", vault.key(value) == KEY
		and vault.key({}) == nil)
	local changed = envelope(); changed.salt = changed.salt:sub(1, -2) .. "2"
	check("a different salt cannot reuse a session key", vault.key(changed) == nil and not vault.acceptHandoff(changed, handoff))
	vault.clear()
	check("lock releases session ownership", vault.key(value) == nil and vault.handoff(value) == nil)
	check("the explicit bootstrap handoff restores the matching key", vault.acceptHandoff(value, handoff) and vault.key(value) == KEY)
	f.env.require("runtime/dispose").drain()
	check("unload releases session ownership", vault.key(value) == nil and vault.handoff(value) == nil)
	f.healthy(); f.close()
end)

case("derivation cancellation, callback errors and disposal release no partial key", function()
	for _, mode in ipairs({ "cancel-before", "cancel-progress", "clear-progress", "dispose-progress", "callback-error", "crypto-error" }) do
		local f = F.new(); local vault = f.env.require("runtime/credential_vault")
		local work, options = 0, {}
		if mode == "cancel-before" then options.cancelled = function() return true end end
		options.progress = function(done)
			if done == 0 then return end
			if mode == "cancel-progress" then return false end
			if mode == "clear-progress" then vault.clear() end
			if mode == "dispose-progress" then f.env.require("runtime/dispose").drain() end
			if mode == "callback-error" then error("sensitive fixture callback detail") end
		end
		f.loaded["runtime/credential_crypto"] = { derive = function(_, _, _, progress)
			if not progress(0, 1200000) then return nil end
			work = work + 1
			if mode == "crypto-error" then error("sensitive fixture crypto detail") end
			if not progress(1024, 1200000) then return nil end
			return KEY
		end }
		local key, why = vault.derive("synthetic fixture password", envelope(), options)
		check("cancelled or failed work cannot return or install a key", key == nil and type(why) == "string" and vault.key(envelope()) == nil)
		check("errors contain no callback details or secrets", not why:find("sensitive", 1, true) and not why:find("password", 1, true))
		if mode == "cancel-before" then check("pre-cancellation prevents expensive work", work == 0) end
		f.healthy(); f.close()
	end
end)

case("creation needs a valid password and host salt without activating a key", function()
	local f = F.new(); local vault = f.env.require("runtime/credential_vault")
	local calls = 0
	f.loaded["runtime/credential_crypto"] = { derive = function() calls = calls + 1; return KEY end }
	local value, key = vault.create("synthetic fixture phrase")
	check("creation chooses the faster work factor and returns the derived key", value and value.iterations == 100000 and key == KEY and calls == 1)
	check("creation does not activate an unverified key", vault.key(value) == nil)
	check("a short setup password cannot derive", vault.create("short") == nil and calls == 1)
	f.env.hs.GenerateGUID = function() error("sensitive host detail") end
	local failed, failedKey, why = vault.create("synthetic fixture phrase")
	check("salt failures preserve private host details and skip derivation", failed == nil and failedKey == nil
		and calls == 1 and not why:find("sensitive", 1, true))
	f.healthy(); f.close()
end)

suite.finish()
