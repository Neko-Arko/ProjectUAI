-- Focused 3.2 default provider, migration and model-discovery contracts.
-- All inference responses are synthetic; no private credential is used.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Project UAI Free")
local case, check = suite.case, suite.check
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end

case("an empty setup receives a usable free provider without network setup", function()
	local f = F.new()
	local registry = f.env.require("provider/registry")
	local free = f.env.require("provider/free")
	free.start()
	local record = registry.active()
	check("free provider is active", record and record.label == "Project UAI Free" and registry.count() == 1)
	check("included credential and supported router are ready", f.env.require("provider/community_key").isApplied(record)
		and record.model == "auto" and record.models[1] == "auto" and registry.validate(record))
	check("default setup sends no traffic", f.h.http.requestCount == 0)
	free.start(); free.use()
	check("restarting and choosing free access do not duplicate it", registry.count() == 1)
	f.h.http.handler = function(entry)
		local body = f.h.json.decode(entry.body)
		check("first inference uses official endpoint and auto", entry.url == "https://api.hcnsec.cn/v1/chat/completions" and body.model == "auto")
		check("included access authenticates", f.env.require("net/headers").get(entry.headers, "Authorization") == "Bearer " .. record.apiKey)
		return { StatusCode = 200, Body = f.h.json.encode({ choices = { { message = { role = "assistant", content = "Ready" }, finish_reason = "stop" } } }) }
	end
	local reply = f.run(function()
		return f.env.require("provider/chat").complete(record, { messages = { { role = "user", content = "Hello" } }, stream = false })
	end)
	check("first conversation completes without configuration", reply and reply.content == "Ready")
	free.stop(); f.healthy(); f.close()
end)

case("saved providers and deliberately disabled selections are preserved", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local record = registry.blank("hcnsec")
	record.label, record.apiKey, record.model, record.enabled = "My account", "personal-fixture-key", "chosen-model", false
	assert(registry.save(record))
	f.env.require("provider/free").start()
	check("existing selection is not replaced", registry.count() == 1 and registry.active() == record)
	check("personal settings stay intact", record.apiKey == "personal-fixture-key" and record.model == "chosen-model" and record.enabled == false)
	check("personal account models are not mislabeled free", not f.env.require("provider/models").isFree(record, "chosen-model"))
	f.env.require("provider/free").stop(); f.healthy(); f.close()
end)

case("missing selection adopts an existing enabled provider", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local record = registry.blank("ollama"); record.model = "existing-model"; assert(registry.save(record))
	f.env.require("runtime/config").set("providers.active", "missing-id")
	f.env.require("provider/free").start()
	check("existing provider gets the selection", registry.count() == 1 and f.env.require("runtime/config").get("providers.active") == record.id)
	f.env.require("provider/free").stop(); f.healthy(); f.close()
end)

case("remove is respected and empty imports or next startup restore free access", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local config, free = f.env.require("runtime/config"), f.env.require("provider/free")
	free.start(); registry.remove(registry.active().id)
	check("explicit removal stays removed in this session", registry.count() == 0)
	free.stop(); free.start()
	check("next start restores an otherwise empty setup", registry.count() == 1 and registry.active().model == "auto")
	config.replace({ providers = { active = "", list = {} } })
	check("an empty import receives included free access", registry.count() == 1 and registry.active().label == "Project UAI Free")
	config.reset("providers")
	check("provider reset receives included free access", registry.count() == 1)
	free.stop(); registry.remove(registry.active().id); config.reset("providers")
	check("stopped bootstrap releases its listener", registry.count() == 0)
	free.start(); registry.remove(registry.active().id)
	f.env.require("runtime/dispose").drain(); config.reset("providers")
	check("client unload releases the free provider listener", registry.count() == 0)
	f.healthy(); f.close()
end)

case("retired OpenCode endpoints migrate on list and normalize pasted variants", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local config = f.env.require("runtime/config")
	local variants = {
		"https://puai-proxy.davidzk.tech/opencode/v1",
		"puai-proxy.davidzk.tech/opencode",
		"https://PUAI-PROXY.DAVIDZK.TECH:443/opencode/v1/chat/completions?old=route",
		"https://puai-free-gateway.renern.workers.dev/opencode/v1/models",
		"http://puai-proxy.davidzk.tech/opencode/v1/",
	}
	local records = {}
	for index, base in ipairs(variants) do
		check("pasted route normalizes " .. index, registry.normaliseBaseUrl(base) == "https://opencode.ai/zen/v1")
		records[index] = { id = "retired-" .. index, baseUrl = base, apiKey = "preserved-key", model = "saved-model", wsUrl = "wss://old-gateway.fixture" }
	end
	local custom = { id = "custom", baseUrl = "https://custom.fixture/opencode/v1", apiKey = "custom-key" }
	records[#records + 1] = custom
	config.set("providers.list", records)
	registry.list()
	for index = 1, #variants do
		local record = records[index]
		check("saved route migrates without credentials/model loss " .. index,
			record.baseUrl == "https://opencode.ai/zen/v1" and record.apiKey == "preserved-key" and record.model == "saved-model" and record.wsUrl == "")
		check("retired route never becomes a proxy candidate " .. index, not registry.proxyProvider(record) and not registry.proxyTarget(record))
	end
	check("custom route stays intact", custom.baseUrl == "https://custom.fixture/opencode/v1")
	check("migration is idempotent", registry.migrate() == 0)
	for _, base in ipairs({ "https://puai-proxy.davidzk.tech.evil.test/opencode/v1", "https://puai-proxy.davidzk.tech:8443/opencode/v1", "https://puai-proxy.davidzk.tech/opencode-other/v1" }) do
		check("unrelated endpoint stays intact", registry.normaliseBaseUrl(base) == base)
	end
	local worker = { baseUrl = "https://puai-free-gateway.renern.workers.dev/agentrouter/v1" }
	check("Workers.dev is not a supported proxy or recovery target", registry.proxyProvider(worker) == nil and registry.proxyTarget(worker) == nil)
	check("only the proper proxy domain inherits AgentRouter identity", registry.proxyProvider({ baseUrl = "https://puai-proxy.davidzk.tech/agentrouter/v1" }) == "agentrouter")
	f.healthy(); f.close()
end)

case("OpenCode discovery uses the connected CLI and expires when connection changes", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local connection = { enabled = true, source = "desktop", port = 28791, token = "fixture-one", instance = "fixture-instance" }
	local available, calls, delayed = true, 0, false
	f.loaded["net/bridge_connection"] = { get = function() return connection end }
	f.loaded["net/bridge"] = {
		opencodeStatus = function() return { available = available, state = available and "ready" or "disconnected" } end,
		opencodeModels = function()
			calls = calls + 1
			if delayed then f.h.sched.wait(2) end
			return { data = { { id = "cat-jam-free" }, { id = "big-pickle" }, { id = "cat-jam-free" } } }
		end,
	}
	local models = f.env.require("provider/models"); local record = registry.blank("zen")
	local found, note = models.discover(record)
	check("current native models are deduplicated and sorted", #found == 2 and found[1] == "big-pickle" and found[2] == "cat-jam-free")
	check("source is disclosed with no direct API request", has(note, "OpenCode CLI") and f.h.http.requestCount == 0)
	models.discover(record)
	check("current connection can use its cache", calls == 1)
	connection.token = "fixture-two"
	check("connection changes invalidate model cache", models.cached(record) == nil)
	delayed = true
	local late
	f.h.sched.spawn(function() late = { models.discover(record) } end)
	f.h.sched.advance(0.1); connection.token = "fixture-three"; f.h.sched.advance(3)
	check("late old connection results cannot publish", late and #late[1] == 0 and has(late[2], "connection changed") and models.cached(record) == nil)
	check("superseded discovery includes support", has(late[2], "https://discord.gg/9xYyyYuKap"))
	available = false
	f.h.http.handler = function() return { StatusCode = 403, Body = '{"error":{"type":"FreeTierError","message":"OpenCode free tier can only be used from within OpenCode"}}' } end
	local rejected, why = f.run(function() return models.discover(record) end)
	check("unavailable mobile route reports the relay requirement", #rejected == 0 and has(why, "UAI Relay app") and has(why, "https://discord.gg/9xYyyYuKap"))
	check("failure never targets the retired proxy", f.h.http.requestCount == 1)
	f.healthy(); f.close()
end)

case("only verified native free models waive personal key entry", function()
	local f = F.ui(900, 800); local registry = f.env.require("provider/registry")
	local available, state, cowork = true, "ready", true
	f.loaded["net/bridge"] = {
		opencodeStatus = function() return { available = available, state = state } end,
		opencodeHasModel = function(id) return id == "cat-jam-free" or id == "big-pickle" or id == "paid-model" end,
	}
	f.loaded["net/transport"] = { coworkWeb = function() return cowork end }
	local record = registry.blank("zen"); record.model = "cat-jam-free"
	check("a discovered native free model needs no personal key", registry.validate(record))
	record.model = "big-pickle"
	check("the verified unsuffixed free model is supported", registry.validate(record))
	for _, model in ipairs({ "paid-model", "unknown-free" }) do
		record.model = model
		check("unverified or paid model keeps normal auth", not registry.validate(record))
	end
	record.model = "cat-jam-free"
	for _, base in ipairs({ "https://custom.fixture/zen/v1", "http://opencode.ai/zen/v1", "https://opencode.ai:8443/zen/v1", "https://opencode.ai/custom/v1" }) do
		record.baseUrl = base
		check("unrelated routes keep normal auth", not registry.validate(record))
	end
	record.baseUrl = "https://opencode.ai/zen/v1"
	record.api = "anthropic"
	check("the Messages adapter keeps normal auth", not registry.validate(record))
	record.api = "openai"; available = false
	check("a disconnected backend keeps normal auth", not registry.validate(record))
	available = true; state = "starting"
	check("a backend still starting keeps normal auth", not registry.validate(record))
	state = "ready"; cowork = false
	check("direct desktop keeps normal auth", not registry.validate(record))
	cowork = true
	f.env.require("ui/panels/providers").editor(record, function(id) f.saved = registry.get(id) end)
	check("the editor explains native authentication", f.h.byName("KeyState").Text == "Provided by connected OpenCode CLI")
	f.h.click(assert(f.h.byName("SaveProvider")))
	check("the verified CLI model saves without a personal key", f.saved and f.saved.apiKey == "" and f.saved.model == "cat-jam-free")
	check("validation never makes network requests", f.h.http.requestCount == 0)
	f.healthy(); f.close()
end)

case("free setup and introduction are available without key entry", function()
	local f = F.ui(390, 760); local registry = f.env.require("provider/registry")
	f.env.require("ui/panels/providers").editor(registry.blank("hcnsec"), function(id) f.saved = registry.get(id) end)
	check("free setup explains included access", has(f.h.textOf(), "No account, payment or personal API key") and has(f.h.textOf(), "https://discord.gg/9xYyyYuKap"))
	f.h.click(assert(f.h.byName("SaveProvider")))
	check("Save needs no key or model edits", f.saved and f.saved.model == "auto" and registry.validate(f.saved))
	f.env.require("ui/panels/home").card(f.host, 1)
	local intro = assert(f.h.byName("FreeIntroductionText"))
	check("welcome thanks continued support and explains capacity", has(intro.Text, "continued use and support") and has(intro.Text, "availability vary") and has(intro.Text, "More free providers"))
	check("Discord is directly visible", has(f.h.byName("FreeCommunityInvite").Text, "https://discord.gg/9xYyyYuKap"))
	check("all managed-provider models qualify for free filtering", f.env.require("provider/models").isFree(f.saved, "auto"))
	check("setup and introduction send no inference", f.h.http.requestCount == 0)
	f.healthy(); f.close()
end)

suite.finish()
