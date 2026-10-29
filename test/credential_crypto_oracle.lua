-- JSON/hex adapter for the independent Python interoperability test.
-- This runs source modules against the normal offline host; no live credentials.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local fixture = F.new()
local json = fixture.h.json
local crypto = fixture.env.require("runtime/credential_crypto")
local sha = fixture.env.require("runtime/credential_sha256")
local aes = fixture.env.require("runtime/credential_aes")
local function binary(value)
	assert(type(value) == "string" and #value % 2 == 0 and not value:find("[^%x]"), "invalid test hex")
	return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end
local function hex(value)
	return (value:gsub(".", function(character) return string.format("%02x", string.byte(character)) end))
end
local requests = json.decode(io.read("*a"))
assert(type(requests) == "table", "expected test request array")
local results = {}
for index, request in ipairs(requests) do
	local value, why
	if request.op == "digest" then value, why = sha.digest(binary(request.text))
	elseif request.op == "hmac" then value, why = sha.hmac(binary(request.key), binary(request.text))
	elseif request.op == "derive" then value, why = crypto.derive(binary(request.password), binary(request.salt), request.iterations)
	elseif request.op == "cmac" then value, why = crypto.cmac(binary(request.key), binary(request.text))
	elseif request.op == "aes" then
		local cipher
		cipher, why = aes.new(binary(request.key))
		if cipher then value, why = cipher.encrypt(binary(request.text)) end
	elseif request.op == "seal" or request.op == "open" then
		local associated = {}
		for item, text in ipairs(request.aad or {}) do associated[item] = binary(text) end
		value, why = crypto[request.op](binary(request.key), binary(request.text), associated)
	else error("unknown test operation") end
	if value == nil then
		assert(type(why) == "string" and why ~= "", "failed crypto operation omitted its error")
		results[index] = { ok = false, error = why }
	else
		assert(type(value) == "string", "crypto operation returned nonbinary data")
		results[index] = { ok = true, value = hex(value) }
	end
end
fixture.healthy()
fixture.close()
io.write(json.encode(results), "\n")
