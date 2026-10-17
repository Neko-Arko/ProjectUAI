-- Go provider/catalog isolation and identity; all keys and replies are synthetic.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("OpenCode Go registry")
local case, check = suite.case, suite.check
local function has(value, part) return tostring(value):find(part, 1, true) ~= nil end

case("Go has a distinct preset and recognized canonical and legacy routes", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local record = registry.blank("opencode-go")
	check("Go is a keyed preset with no invented model", record.preset == "opencode-go"
		and record.baseUrl == "https://opencode.ai/inference/go/v1" and record.apiKey == ""
		and record.authStyle == "bearer" and record.model == "" and #record.models == 0)
	for _, base in ipairs({ "https://opencode.ai/inference/go/v1", "https://opencode.ai/zen/go/v1" }) do
		for _, suffix in ipairs({ "", "/chat/completions", "/responses", "/messages", "/models" }) do
			record.baseUrl = base .. suffix .. "?tenant=fixture"
			check("documented Go route recognized", registry.isOpencodeGo(record) and not registry.isOpencodeZen(record))
			check("Go path and query survive discovery", registry.endpoint(record, "/models") == base .. "/models?tenant=fixture")
		end
	end
	for _, base in ipairs({ "https://opencode.ai/zen/v1", "https://opencode.ai/inference/go/v1-other",
		"https://opencode.ai/custom/go/v1", "https://opencode.ai:8443/inference/go/v1", "https://other.example/inference/go/v1" }) do
		record.baseUrl = base
		check("unrelated routes are not Go", not registry.isOpencodeGo(record))
	end
	for _, base in ipairs({ "https://puai-proxy.davidzk.tech/opencode/v1", "https://puai-free-gateway.renern.workers.dev/opencode/v1" }) do
		record.baseUrl, record.model = base, "deepseek-v4.1-flash"
		check("ambiguous historical proxy remains Zen", registry.normaliseBaseUrl(base) == "https://opencode.ai/zen/v1"
			and not registry.isOpencodeGo(record) and registry.isOpencodeZen(record))
	end
	f.healthy(); f.close()
end)

case("documented Go protocols select model families without rewriting Zen", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local record = registry.blank("opencode-go")
	local models = { ["deepseek-v4.1-flash"] = "openai", ["gpt-5.4"] = "responses", ["grok-4.7"] = "responses",
		["muse-spark-1.3-contributor"] = "responses", ["claude-sonnet-4-6"] = "anthropic",
		["minimax-m3"] = "anthropic", ["qwen3.8-max"] = "anthropic", ["gemini-4-argon-contributor"] = "gemini" }
	for model, protocol in pairs(models) do
		record.model = model
		check("Go family protocol " .. model, registry.opencodeGoProtocol(record) == protocol)
	end
	record.model = "gemini-4-argon-contributor"
	check("native Gemini selects its implemented adapter", registry.protocolProblem(record) == nil and f.env.require("provider/chat").styleOf(record) == "gemini")
	check("Gemini selection permits the shared Go model list", registry.protocolProblem(record, { discovery = true }) == nil)
	record.model, record.baseUrl = "gpt-5.4", "https://opencode.ai/zen/go/v1/responses"
	check("full Go Responses route is allowed", registry.protocolProblem(record) == nil)
	record.baseUrl = "https://opencode.ai/zen/v1"
	check("Zen receives no Go protocol override", registry.opencodeGoProtocol(record) == nil)
	f.healthy(); f.close()
end)

case("Go headers identify Project UAI and preserve explicit overrides and session affinity", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local record = registry.blank("opencode-go"); record.model, record.apiKey = "deepseek-v4.1-flash", "fixture-key"
	local context = { sessionId = "fixture-conversation" }
	local first, second = registry.opencodeHeaders(record, context), registry.opencodeHeaders(record, context)
	check("Go uses the application's own identity", first["User-Agent"] == "ProjectUAI/" .. f.env.info.version)
	check("Go session affinity remains stable", registry.validOpencodeSession(first["x-opencode-session"])
		and first["x-opencode-session"] == second["x-opencode-session"])
	check("Go omits desktop impersonation headers", first["x-opencode-client"] == nil and first["accept"] == nil)
	record.headers = { ["User-Agent"] = "FixtureApplication/1", ["x-opencode-session"] = "fixture-override" }
	local final = f.env.require("provider/chat").headers(record, context)
	check("custom headers remain authoritative", final["User-Agent"] == "FixtureApplication/1" and final["x-opencode-session"] == "fixture-override")
	check("Go keeps bearer authentication", final.Authorization == "Bearer fixture-key")
	f.healthy(); f.close()
end)

case("Go discovery and authentication never use the connected native free catalog", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local bridgeReads, cliReads, currentToken = 0, 0, "first"
	f.loaded["net/bridge"] = {
		opencodeStatus = function() bridgeReads = bridgeReads + 1; return { available = true, state = "ready" } end,
		opencodeModels = function() cliReads = cliReads + 1; return { data = { { id = "big-pickle" } } } end,
		opencodeHasModel = function() return true end,
	}
	f.loaded["net/bridge_connection"] = { get = function() return { token = currentToken } end }
	f.loaded["net/transport"] = { coworkWeb = function() return true end }
	local record = registry.blank("opencode-go"); record.apiKey, record.model = "fixture-key", "deepseek-v4.1-flash"
	local models = f.env.require("provider/models")
	f.h.http.handler = function(entry)
		check("discovery keeps the Go route", entry.url == "https://opencode.ai/inference/go/v1/models")
		check("discovery retains the user credential", entry.headers.Authorization == "Bearer fixture-key")
		return { StatusCode = 200, Body = '{"data":[{"id":"deepseek-v4.1-flash"},{"id":"gemini-4-argon-contributor"}]}' }
	end
	local found, note = f.run(function() return models.discover(record) end)
	check("Go keeps all server IDs without native substitution", #found == 2 and found[1] == "deepseek-v4.1-flash"
		and cliReads == 0 and bridgeReads == 0 and f.h.http.requestCount == 1)
	check("public discovery does not claim subscription verification", has(note, "public list") and has(note, "subscription"))
	currentToken = "second"
	check("unrelated native connection changes leave Go cache intact", models.cached(record) == found)
	record.apiKey = ""
	record.model = "cat-jam-free"
	check("Go always requires its own credential", not registry.opencodeKeyOptional(record) and not registry.validate(record))
	check("Go is not advertised as included free access", not models.isFree(record, "cat-jam-free") and not models.isFree(record, "big-pickle"))
	check("Go auth changes expire its model cache", models.cached(record) == nil)
	f.healthy(); f.close()
end)

suite.finish()
