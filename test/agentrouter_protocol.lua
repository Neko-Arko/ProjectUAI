package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("agentrouter_fixture")
local suite = F.suite("AgentRouter protocols")
local case, check = suite.case, suite.check

case("GPT routes use native Responses without constructing a discarded Chat payload", function()
	local f = F.new()
	local openai = f.env.require("provider/openai")
	openai.buildBody = function() error("unused Chat payload was built") end
	f.handler(function(entry)
		local body = f.h.json.decode(entry.body)
		check("native selected endpoint", entry.url == "https://agentrouter.org/v1/responses")
		check("existing preset authentication and identity survive", entry.headers["x-api-key"] == "fixture-key" and entry.headers["x-app"] == "cli")
		check("low effort and stateless history are explicit", body.reasoning.effort == "low" and body.store == false and body.previous_response_id == nil)
		check("native serializer is used", body.input[1].content == "Inspect the fixture" and body.messages == nil)
		return f.reply()
	end)
	local result = f.complete()
	check("one request completes through legacy Messages preset", result and result.content == "fixture complete" and #f.sent == 1 and f.record.api == "anthropic")
	check("endpoint presentation agrees with transport", f.chat.endpointOf(f.record) == "https://agentrouter.org/v1/responses")
	f.finish()
end)

case("only documented AgentRouter routes inherit GPT protocol behavior", function()
	local f = F.new()
	for _, base in ipairs({ "https://agentrouter.org", "https://api.agentrouter.org:443/v1", "https://ps.air-outer.com/v1",
		"https://agentrouter.org/v1/chat/completions", "https://puai-proxy.davidzk.tech/agentrouter/v1" }) do
		f.record.baseUrl = base
		check("known route selects Responses " .. base, f.registry.isAgentRouter(f.record) and f.chat.styleOf(f.record) == "openai"
			and f.chat.endpointOf(f.record):find("/responses", 1, true) ~= nil)
	end
	for _, base in ipairs({ "http://agentrouter.org/v1", "https://agentrouter.org:8443/v1", "https://agentrouter.org/custom/v1",
		"https://agentrouter.org.evil.test/v1", "https://custom.test/v1", "https://puai-proxy.davidzk.tech/other/v1",
		"https://agentrouter.org/v1/responses/messages" }) do
		f.record.baseUrl = base
		check("custom route retains chosen protocol " .. base, not f.registry.isAgentRouter(f.record) and f.chat.styleOf(f.record) == "anthropic")
	end
	f.record.baseUrl = "https://agentrouter.org/v1/responses"
	check("explicit Responses endpoint passes validation", f.registry.protocolProblem(f.record) == nil)
	f.record.baseUrl, f.record.model = "https://agentrouter.org", "claude-opus-5-5"
	check("non-GPT models retain Messages", f.chat.styleOf(f.record) == "anthropic" and f.chat.endpointOf(f.record) == "https://agentrouter.org/v1/messages")
	f.finish()
end)

case("documented effort controls preserve request overrides and provider defaults", function()
	local f = F.new(); local traits = f.env.require("provider/traits")
	check("current GPT exact effort scales are known", #traits.effortLevels("gpt-6.1-sol") == 5 and #traits.effortLevels("openai/gpt-6-astra") == 5)
	check("lookalike model names do not gain an effort claim", traits.effortLevels("not-gpt-6.1-sol-custom") == nil)
	for _, level in ipairs({ "low", "medium", "high", "xhigh", "max" }) do
		local body = f.responses.buildBody(f.record, { messages = {}, effort = level })
		check("request effort " .. level, body.reasoning.effort == level)
	end
	check("unsupported minimal maps to lowest supported effort", f.responses.buildBody(f.record, { messages = {}, effort = "minimal" }).reasoning.effort == "low")
	check("off intentionally leaves provider default", f.responses.buildBody(f.record, { messages = {}, effort = "off" }).reasoning == nil)
	local body = f.responses.buildBody(f.record, { messages = {}, extra = { reasoning = { effort = "high" }, store = true } })
	check("explicit raw overrides retain their contract", body.reasoning.effort == "high" and body.store == true)
	f.record.baseUrl = "https://opencode.ai/zen/v1"
	body = f.responses.buildBody(f.record, { messages = {} })
	check("AgentRouter defaults do not change OpenCode requests", body.reasoning == nil and body.store == nil)
	f.finish()
end)

case("optional tool schemas remain optional without mutating caller declarations", function()
	local f = F.new()
	local tool = { type = "function", name = "inspect", parameters = { type = "object", properties = { path = { type = "string" } } } }
	local body = f.responses.buildBody(f.record, { messages = {}, tools = { tool }, parallelToolCalls = false })
	check("native function strict default is disabled", body.tools[1].strict == false and body.tools[1].parameters.required == nil)
	check("caller tool stays unchanged", tool.strict == nil and body.tools[1] ~= tool)
	check("explicit serial preference is preserved", body.parallel_tool_calls == false)
	local rawTools = { tool }
	body = f.responses.buildBody(f.record, { messages = {}, extra = { tools = rawTools } })
	check("raw override list and declaration stay unchanged", body.tools ~= rawTools and rawTools[1] == tool
		and rawTools[1].strict == nil and body.tools[1].strict == false)
	body = f.responses.buildBody(f.record, { messages = {}, tools = {{ type = "function", ["function"] = {
		name = "strict_tool", strict = true, parameters = { type = "object", properties = {}, additionalProperties = false } } }} })
	check("explicit strict declaration survives translation", body.tools[1].strict == true)
	local many = {}
	for index = 1, 140 do many[index] = { type = "function", ["function"] = { name = "tool_" .. index, parameters = { type = "object", properties = {} } } } end
	body = f.responses.buildBody(f.record, { messages = {}, tools = many })
	check("large catalog stays usable through the bounded router", #body.tools == 128 and body.tools[#body.tools].name:find("uai_tool_catalog", 1, true) ~= nil)
	for _, definition in ipairs(body.tools) do check("all bounded tools preserve optional schemas", definition.strict == false) end
	f.finish()
end)

suite.finish()
