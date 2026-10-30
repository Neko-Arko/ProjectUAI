-- Key ownership through real provider adapters and synthetic HTTP only.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Provider key snapshots")
local case, check = suite.case, suite.check

local function recordFor(f, api)
	local record = f.env.require("provider/registry").blank("custom")
	record.id, record.label = "key-fixture", "Key fixture"
	record.baseUrl, record.model = "https://keys.fixture/v1", "fixture-model"
	record.api, record.authStyle, record.apiKey = api or "openai", "bearer", "A\nB\nC"
	return record
end

local function credential(f, headers)
	local get = f.env.require("net/headers").get
	local bearer = get(headers, "Authorization")
	return bearer and bearer:gsub("^Bearer ", "") or get(headers, "x-api-key")
end

local function modelsReply(f)
	return { StatusCode = 200, Body = f.h.json.encode({ data = { { id = "fixture-model" } } }) }
end

local function completionReply(f, api)
	if api == "anthropic" then
		return { StatusCode = 200, Body = f.h.json.encode({ type = "message", role = "assistant",
			model = "fixture-model", content = { { type = "text", text = "ready" } }, stop_reason = "end_turn",
			usage = { input_tokens = 1, output_tokens = 1 } }) }
	end
	return { StatusCode = 200, Body = f.h.json.encode({ choices = { {
		message = { role = "assistant", content = "ready" }, finish_reason = "stop" } } }) }
end

local function request()
	return { messages = { { role = "user", content = "hello" } }, stream = false, attempts = 1, maxTokens = 16 }
end

case("forced model discovery rotates the source pool and cached reads take no key", function()
	local f = F.new(); local record = recordFor(f)
	local models, seen = f.env.require("provider/models"), {}
	f.h.http.handler = function(entry)
		seen[#seen + 1] = credential(f, entry.headers)
		return modelsReply(f)
	end
	local first = f.run(function() return models.discover(record, { force = true }) end)
	local cached, note = f.run(function() return models.discover(record) end)
	check("a cached list performs no HTTP request", first[1] == "fixture-model" and cached[1] == first[1]
		and note == "cached" and #seen == 1)
	for _ = 1, 2 do
		local found = f.run(function() return models.discover(record, { force = true }) end)
		check("forced discovery returns the reported model", found[1] == "fixture-model")
	end
	check("discovery snapshots reserve A then B then C", table.concat(seen, ",") == "A,B,C")
	f.healthy(); f.close()
end)

case("legacy Anthropic headers advance the original record without an authStyle", function()
	local f = F.new(); local record = recordFor(f, "anthropic"); record.authStyle = nil
	local adapter, seen = f.env.require("provider/anthropic"), {}
	for _ = 1, 3 do
		local headers = adapter.headers(record)
		seen[#seen + 1] = headers["x-api-key"]
		check("default Messages headers contain one named credential", headers.Authorization == nil
			and headers["anthropic-version"] == "2023-06-01")
	end
	check("default auth copies retain source rotation", table.concat(seen, ",") == "A,B,C" and record.authStyle == nil)
	check("an explicit retry key does not consume another slot", adapter.headers(record, "retry-key")["x-api-key"] == "retry-key"
		and adapter.headers(record)["x-api-key"] == "A")
	f.healthy(); f.close()
end)

for _, api in ipairs({ "openai", "anthropic" }) do
	case(api .. " overlapping snapshot completions reserve distinct keys before returning", function()
		local f = F.new(); local record = recordFor(f, api)
		if api == "anthropic" then record.authStyle = nil end
		local registry, util = f.env.require("provider/registry"), f.env.require("runtime/util")
		local chat, snapshots = f.env.require("provider/chat"), {}
		-- All three copies exist before the first key is selected.
		for index = 1, 3 do snapshots[index] = registry.shareKeyRotation(record, util.deepCopy(record)) end
		local seen, results, finished, release = {}, {}, 0, false
		f.h.http.handler = function(entry)
			seen[#seen + 1] = credential(f, entry.headers)
			while not release do f.h.sched.wait(0.05) end
			return completionReply(f, api)
		end
		for index = 1, 3 do
			local slot = index
			f.h.sched.spawn(function()
				results[slot] = chat.complete(snapshots[slot], request())
				finished = finished + 1
			end)
		end
		f.h.sched.advance(0.1)
		check("all pending requests already own a different key", finished == 0 and table.concat(seen, ",") == "A,B,C")
		release = true; f.h.sched.advance(0.3)
		check("all three real adapter completions settle", finished == 3 and results[1] and results[2] and results[3]
			and results[1].content == "ready" and results[2].content == "ready" and results[3].content == "ready")
		f.healthy(); f.close()
	end)
end

case("intentional request snapshots share cooldowns while a separate editor draft stays isolated", function()
	local f = F.new(); local record = recordFor(f)
	local registry, util = f.env.require("provider/registry"), f.env.require("runtime/util")
	local chat = f.env.require("provider/chat")
	local snapshot = registry.shareKeyRotation(record, util.deepCopy(record))
	check("a request copy starts the common cursor", credential(f, chat.headers(snapshot)) == "A")
	local draft = util.deepCopy(record)
	registry.cooldownKey(snapshot, "B", 30)
	check("snapshot cooldowns apply to the original request pool", credential(f, chat.headers(record)) == "C")
	check("draft cursor and cooldowns remain independent", credential(f, chat.headers(draft)) == "B"
		and registry.keyCooldowns(draft).B == nil)
	registry.cooldownKey(draft, "A", 30)
	check("draft cooldowns cannot bench a live pool key", credential(f, chat.headers(snapshot)) == "A"
		and registry.keyCooldowns(record).A == nil)
	f.healthy(); f.close()
end)

case("model proxy recovery retains one key and the following completion uses the next", function()
	local f = F.new(); local record = recordFor(f)
	record.baseUrl = "https://agentrouter.org/v1"
	local seen, urls = {}, {}
	f.h.http.handler = function(entry)
		seen[#seen + 1], urls[#urls + 1] = credential(f, entry.headers), entry.url
		if #seen == 1 then
			return { StatusCode = 403, Body = f.h.json.encode({ error = { type = "UnauthorizedClientError", message = "unauthorized client" } }) }
		end
		return entry.method == "GET" and modelsReply(f) or completionReply(f, "openai")
	end
	local found = f.run(function() return f.env.require("provider/models").discover(record, { force = true }) end)
	check("one discovery recovery reuses its selected credential", found[1] == "fixture-model" and table.concat(seen, ",") == "A,A"
		and urls[1] == "https://agentrouter.org/v1/models"
		and urls[2] == "https://puai-proxy.davidzk.tech/agentrouter/v1/models")
	local result = f.run(function() return f.env.require("provider/chat").complete(record, request()) end)
	check("the next logical operation receives B", result and result.content == "ready" and table.concat(seen, ",") == "A,A,B")
	f.healthy(); f.close()
end)

case("accepted rotating and fixed snapshots retain their policy across later selection changes", function()
	local f = F.new(); local record = recordFor(f)
	local registry, keys = f.env.require("provider/registry"), f.env.require("runtime/provider_keys")
	assert(keys.rename(record, 2, "Backup"))
	local rotating = registry.requestSnapshot(record)
	check("the rotating snapshot reserves the first ready key", registry.nextKey(rotating) == "A")
	assert(keys.setMode(record, "single", 3))
	check("later fixed selection does not alter an accepted rotating request", registry.nextKey(record) == "C"
		and registry.nextKey(rotating) == "B" and keys.mode(rotating) == "rotate")
	local fixed = registry.requestSnapshot(record)
	assert(keys.setMode(record, "single", 2))
	assert(keys.rename(record, 2, "Renamed backup"))
	check("a fixed snapshot keeps its selected key and copied names", registry.nextKey(fixed) == "C" and registry.nextKey(fixed) == "C"
		and registry.nextKey(record) == "B" and fixed.keyNames[2] == "Backup")
	f.healthy(); f.close()
end)

case("legacy Gemini authentication advances the original pool and respects fixed selection", function()
	local f = F.new(); local record = recordFor(f, "gemini")
	record.authStyle = nil
	local adapter, keys = f.env.require("provider/gemini"), f.env.require("runtime/provider_keys")
	check("implicit Gemini auth rotates its owning record", adapter.headers(record)["x-goog-api-key"] == "A"
		and adapter.headers(record)["x-goog-api-key"] == "B" and adapter.headers(record)["x-goog-api-key"] == "C")
	assert(keys.setMode(record, "single", 2))
	check("implicit auth honors the chosen key without rewriting the provider", adapter.headers(record)["x-goog-api-key"] == "B"
		and adapter.headers(record)["x-goog-api-key"] == "B" and record.authStyle == nil)
	f.healthy(); f.close()
end)

case("model discovery caches belong to the selected credential and mode, not its name", function()
	local f = F.new(); local record = recordFor(f)
	local keys, models = f.env.require("runtime/provider_keys"), f.env.require("provider/models")
	assert(keys.setMode(record, "single", 1))
	local seen = {}
	f.h.http.handler = function(entry)
		local key = credential(f, entry.headers)
		seen[#seen + 1] = key
		return { StatusCode = 200, Body = f.h.json.encode({ data = { { id = "model-" .. key } } }) }
	end
	local first = f.run(function() return models.discover(record) end)
	assert(keys.setMode(record, "single", 2))
	local second = f.run(function() return models.discover(record) end)
	check("changing the chosen key fetches its own authenticated catalog", first[1] == "model-A" and second[1] == "model-B"
		and table.concat(seen, ",") == "A,B")
	assert(keys.rename(record, 2, "Backup"))
	local cached, note = f.run(function() return models.discover(record) end)
	check("renaming retains the same catalog without consuming a request", cached[1] == "model-B" and note == "cached" and #seen == 2)
	assert(keys.setMode(record, "rotate"))
	local rotated = f.run(function() return models.discover(record) end)
	check("switching to rotation cannot reuse a fixed-credential catalog", rotated[1] == "model-A" and table.concat(seen, ",") == "A,B,A")
	f.healthy(); f.close()
end)

case("a changed fixed selection rejects pending discovery and proxy recovery from the old key", function()
	local f = F.new(); local record = recordFor(f)
	local keys, models = f.env.require("runtime/provider_keys"), f.env.require("provider/models")
	assert(keys.setMode(record, "single", 1))
	f.h.http.handler = function() local reply = modelsReply(f); reply.delay = 1; return reply end
	local found
	f.h.sched.spawn(function() found = models.discover(record) end)
	f.h.sched.advance(0.1)
	assert(keys.setMode(record, "single", 2))
	f.h.sched.advance(2)
	check("an old authenticated response cannot publish a catalog for the new key", found and #found == 0 and models.cached(record) == nil)
	record.baseUrl = "https://agentrouter.org/v1"
	local recovery = f.env.require("provider/proxy").new(record)
	assert(keys.setMode(record, "single", 3))
	local changed = recovery.recover({ status = 403, body = '{"error":{"message":"Unauthorized client"}}' })
	check("a refusal from another selected key cannot change the current endpoint", not changed and record.baseUrl == "https://agentrouter.org/v1")
	f.healthy(); f.close()
end)

suite.finish()
