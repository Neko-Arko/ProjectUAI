-- CPU-only password stretching benchmark using a synthetic password and salt.
-- Usage: luajit test/credential_crypto_benchmark.lua
--        refer/native-tools/luau/luau.exe test/credential_crypto_benchmark.lua
-- No artificial frame waits: report callback work gaps separately so the UI can
-- throttle its own yields without weakening the configured work factor.
local sha, close
if type(package) == "table" then
	package.path = "test/?.lua;test/mock/?.lua;" .. package.path
	local fixture = require("coding_fixture").new()
	sha, close = fixture.env.require("runtime/credential_sha256"), fixture.close
else
	sha = require("../src/runtime/credential_sha256")({})
end
-- Match the work factor used by newly created vaults.
local iterations = 100000
local started, previous = os.clock(), nil
local callbacks, gapTotal, gapMaximum = 0, 0, 0
local key, why = sha.derive64("synthetic benchmark passphrase only", "public-benchmark-salt-v1", iterations, function(completed, total)
	local now = os.clock()
	if previous then
		local gap = now - previous
		gapTotal, gapMaximum = gapTotal + gap, math.max(gapMaximum, gap)
	end
	previous, callbacks = now, callbacks + 1
	assert(completed >= 0 and completed <= total and total == iterations * 2)
end)
local elapsed = os.clock() - started
assert(type(key) == "string" and #key == 64, why)
print(string.format("PBKDF2-HMAC-SHA256: iterations=%d output=64 bytes CPU=%.3fs callbacks=%d mean-gap=%.3fms max-gap=%.3fms",
	iterations, elapsed, callbacks, gapTotal / math.max(1, callbacks - 1) * 1000, gapMaximum * 1000))
if close then close() end
