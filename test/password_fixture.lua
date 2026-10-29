-- Synthetic password setup for suites that test behavior after authentication.
-- The real AES/envelope/storage path remains active; only derivation is shortened.
return function(harness, client)
	local crypto = client.env.require("runtime/credential_crypto")
	local sha = client.env.require("runtime/credential_sha256")
	crypto.derive = function(password, salt, _, progress)
		if progress and progress(0, 1) == false then return nil, crypto.error end
		local key = sha.digest(password .. "\0" .. salt) .. sha.digest(salt .. "\0" .. password)
		if progress and progress(1, 1) == false then return nil, crypto.error end
		return key
	end
	local result
	harness.sched.spawn(function()
		local method = client.config.vaultStatus().enabled and client.config.unlockVault or client.config.enableVault
		result = { method("synthetic test master password") }
	end)
	harness.settle(1)
	assert(result and result[1], result and result[2] or "fixture password setup did not finish")
	assert(client.config.vaultStatus().ready, "fixture authentication did not release access")
end
