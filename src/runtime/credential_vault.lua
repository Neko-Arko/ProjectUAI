-- Versioned password-vault envelope and private, session-only key ownership.
-- RFC 5297 AES-256-SIV needs no random nonce. A public GUID distinguishes salts;
-- it is not used as secret entropy. The user's password is the only secret input.
return function(env)
	local util = env.require("runtime/util")
	local dispose = env.require("runtime/dispose")
	local M = { iterations = 100000, maxIterations = 2000000, maxBytes = 2 * 1024 * 1024,
		error = "The credential vault is damaged or uses an unsupported format.",
		passwordError = "Incorrect master password, or the encrypted credential data was changed." }
	local sessionKey, sessionHeader
	local epoch = 0
	local function header(value)
		return table.concat({ "Project UAI credential vault", tostring(value.version), value.cipher,
			value.kdf, tostring(value.iterations), value.salt }, "\0")
	end
	function M.validate(value)
		if type(value) ~= "table" or value.version ~= 1 or value.cipher ~= "aes-256-siv"
			or value.kdf ~= "pbkdf2-hmac-sha256" or type(value.iterations) ~= "number"
			or value.iterations < M.iterations or value.iterations > M.maxIterations or value.iterations % 1 ~= 0
			or type(value.salt) ~= "string" or #value.salt < 36 or #value.salt > 128 or value.salt:find("[^a-z0-9:%-]")
			or type(value.data) ~= "string" or #value.data < 32 or #value.data > (M.maxBytes + 16) * 2
			or #value.data % 2 ~= 0 or value.data:find("[^0-9a-f]") then return false, M.error end
		local allowed = { version = true, cipher = true, kdf = true, iterations = true, salt = true, data = true }
		for name in pairs(value) do if not allowed[name] then return false, M.error end end
		return true
	end
	local function hex(value)
		return (value:gsub(".", function(character) return string.format("%02x", string.byte(character)) end))
	end
	local function binary(value)
		return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
	end
	function M.clear()
		sessionKey, sessionHeader = nil, nil
		epoch = epoch + 1
	end
	dispose.add(M.clear, "credential vault key")
	function M.key(value)
		if sessionKey and M.validate(value) and sessionHeader == header(value) then return sessionKey end
	end
	function M.activate(key, value)
		if type(key) ~= "string" or #key ~= 64 or not M.validate(value) then return false, M.error end
		sessionKey, sessionHeader = key, header(value)
		return true
	end
	-- Only bootstrap's private in-memory replacement path uses this value.
	-- It must never enter config.data, exports, diagnostics or a saved file.
	function M.handoff(value)
		local key = M.key(value)
		return key and { key = key, header = sessionHeader } or nil
	end
	function M.acceptHandoff(value, handoff)
		if type(handoff) ~= "table" or not M.validate(value) or handoff.header ~= header(value) then return false end
		return M.activate(handoff.key, value)
	end
	function M.passwordValid(password, creating)
		if type(password) ~= "string" or #password == 0 or #password > 1024 or not util.validUtf8(password) then
			return false, "Enter a valid master password of at most 1,024 UTF-8 bytes."
		end
		if creating then
			local _, characters = password:gsub("[^\128-\191]", "")
			if characters < 12 or util.trim(password) == "" then return false, "Use at least 12 characters, preferably several unrelated words." end
		end
		return true
	end
	function M.derive(password, value, options)
		local valid, why = M.passwordValid(password, false)
		if not valid then return nil, why end
		if not M.validate(value) then return nil, M.error end
		options = options or {}
		local currentEpoch, cancelled, lastYield = epoch, false, os.clock()
		local function progress(done, total)
			if epoch ~= currentEpoch or dispose.draining or (options.cancelled and options.cancelled()) then cancelled = true; return false end
			if options.progress and options.progress(done, total) == false then cancelled = true; return false end
			-- Yield on time, rather than once per hash batch: fast hosts avoid an
			-- artificial frame delay, while slow ones keep Cancel and painting live.
			if os.clock() - lastYield >= 0.012 then task.wait(); lastYield = os.clock() end
			if epoch ~= currentEpoch or (options.cancelled and options.cancelled()) then cancelled = true; return false end
			return true
		end
		local ok, key = pcall(function()
			return env.require("runtime/credential_crypto").derive(password, value.salt, value.iterations, progress)
		end)
		password = nil
		if cancelled then return nil, "Cancelled" end
		if not ok or type(key) ~= "string" or #key ~= 64 then return nil, "Could not derive the vault key on this host." end
		return key
	end
	function M.create(password, options)
		local valid, why = M.passwordValid(password, true)
		if not valid then return nil, nil, why end
		local ok, id = pcall(function() return env.hs:GenerateGUID(false) end)
		if not ok or type(id) ~= "string" or #id ~= 36 or id:find("[^%x%-]") then
			return nil, nil, "This host could not create a unique public vault salt. Your current credentials are unchanged."
		end
		local value = { version = 1, cipher = "aes-256-siv", kdf = "pbkdf2-hmac-sha256",
			iterations = M.iterations, salt = "uai-vault-v1:" .. id:lower(), data = string.rep("0", 32) }
		local key, err = M.derive(password, value, options)
		if not key then return nil, nil, err end
		return value, key
	end
	function M.seal(value, key, payload)
		if not M.validate(value) or type(key) ~= "string" or #key ~= 64 or type(payload) ~= "table" then return nil, M.error end
		local encoded, plain = pcall(util.encode, payload)
		if not encoded or type(plain) ~= "string" or #plain > M.maxBytes then return nil, "Credential data exceeds the vault's 2 MiB limit." end
		local ok, sealed = pcall(function() return env.require("runtime/credential_crypto").seal(key, plain, { header(value) }) end)
		if not ok or type(sealed) ~= "string" then return nil, "Could not encrypt credentials on this host." end
		local out = util.deepCopy(value)
		out.data = hex(sealed)
		return out
	end
	function M.open(value, key)
		if not M.validate(value) then return nil, M.error end
		if type(key) ~= "string" or #key ~= 64 then return nil, M.passwordError end
		local ok, plain = pcall(function()
			return env.require("runtime/credential_crypto").open(key, binary(value.data), { header(value) })
		end)
		if not ok or type(plain) ~= "string" then return nil, M.passwordError end
		local payload = util.decode(plain)
		if type(payload) ~= "table" then return nil, M.error end
		return payload
	end
	return M
end
