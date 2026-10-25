package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("agentrouter_fixture")
local suite = F.suite("AgentRouter Responses lifecycle")
local case, check = suite.case, suite.check

case("explicit native protocol refusals can recover once for an unknown model", function()
	local f = F.new(); f.record.model, f.record.api = "future-fixture", "openai"
	f.handler(function(entry, index)
		if index == 1 then return { StatusCode = 400, Body = f.h.json.encode({ error = {
			message = "Model does not support /v1/chat/completions, please use /v1/responses instead." } }) } end
		check("fallback stays on the same authenticated provider", entry.url == "https://agentrouter.org/v1/responses" and entry.headers["x-api-key"] == "fixture-key")
		return f.reply()
	end)
	local result = f.complete()
	check("one explicit refusal and one native completion", result and #f.sent == 2)
	check("successful native route is remembered in its scope", f.responses.remembered(f.record))
	f.finish()
end)

case("Responses retains bounded authorized proxy recovery and exact body", function()
	local f = F.new(); local firstBody
	f.handler(function(entry, index)
		if index == 1 then firstBody = entry.body; return { StatusCode = 403, Body = '{"error":{"code":"unauthorized_client","message":"Unauthorized client"}}' } end
		check("proxy retains native protocol", entry.url == "https://puai-proxy.davidzk.tech/agentrouter/v1/responses")
		check("proxy retains serialized request and auth", entry.body == firstBody and entry.headers["x-api-key"] == "fixture-key")
		return f.reply()
	end)
	local result = f.complete()
	check("bounded explicit recovery succeeds", result and #f.sent == 2)
	f.finish()
end)

case("stream quota errors and partial output never replay or complete", function()
	local f = F.new()
	f.handler(function()
		return { StatusCode = 200, Body = 'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"partial"}\n\n'
			.. 'event: error\ndata: {"type":"error","code":"rate_limit_exceeded","message":"Regional token quota exceeded"}\n\n' }
	end)
	local result, why = f.complete({ attempts = 4 })
	check("partial reply is rejected with provider quota detail", not result and why:find("rate_limit_exceeded", 1, true))
	check("stream error never sends a duplicate", #f.sent == 1)
	f.finish()
end)

case("Stop and unknown native deadlines stay terminal", function()
	for _, mode in ipairs({ "stop", "deadline" }) do
		local f = F.new(); local stopped = false
		f.handler(function() local reply = f.reply(); reply.delay = 2; return reply end)
		if mode == "stop" then f.h.sched.spawn(function() f.h.sched.wait(0.2); stopped = true end) end
		local result, why = f.complete({ attempts = 4, timeout = 1, aborted = function() return stopped end }, 1.4)
		check(mode .. " has no completion", not result and (mode == "stop" and why == "aborted" or mode == "deadline" and f.env.require("net/http").terminal(why)))
		check(mode .. " admits one native send", #f.sent == 1)
		f.h.settle(1); f.finish()
	end
end)

case("UAI context replays tool results without backend resource references", function()
	local f = F.new(); local ctx = f.env.require("agent/context").new()
	ctx.pushUser("Read the fixture")
	ctx.pushAssistant({ content = "", id = "foreign-response", reasoning = "visible summary", raw = {{ type = "reasoning", encrypted_content = "foreign-ciphertext" }},
		toolCalls = {{ id = "call-fixture", type = "function", ["function"] = { name = "instance_get", arguments = '{"path":"Workspace.Map"}' } }} })
	ctx.pushToolResult("call-fixture", "instance_get", "Name = FixtureMap")
	local body = f.responses.buildBody(f.record, { messages = ctx.wire("Inspect Roblox") })
	local encoded = f.h.json.encode(body)
	check("stateless history retains the complete tool exchange", body.store == false and body.input[2].type == "function_call"
		and body.input[3].type == "function_call_output" and body.input[2].call_id == body.input[3].call_id)
	check("resource IDs and opaque encrypted items are not replayed", not encoded:find("foreign-response", 1, true) and not encoded:find("foreign-ciphertext", 1, true)
		and body.previous_response_id == nil)
	f.finish()
end)

suite.finish()
