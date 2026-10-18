-- Go requests retain their subscription route, credentials and model protocol.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("OpenCode Go adapters")
local check = suite.check
local TOOLS = { { type = "function", ["function"] = { name = "fixture_lookup", description = "Read a fixture",
	parameters = { type = "object", properties = { key = { type = "string" } }, required = { "key" } } } } }
local function recordFor(f, base, model)
	local record = f.env.require("provider/registry").blank("opencode-go")
	record.baseUrl, record.model, record.apiKey = base, model, "fixture-go-key"
	record.query = { mode = "a b" }
	return record
end
for _, path in ipairs({ "/inference/go/v1", "/zen/go/v1" }) do
	for _, row in ipairs({ { "deepseek-v4.1-flash", "chat/completions" }, { "gpt-6-luna", "responses" }, { "claude-haiku-5-5", "messages" } }) do
		suite.case(path .. " retains " .. row[2] .. " tools and results", function()
			local f = F.new(); f.env.info.version = "3.2.0"
			local record = recordFor(f, "https://opencode.ai" .. path .. "?tenant=one", row[1])
			local chat, headers = f.env.require("provider/chat"), f.env.require("net/headers")
			local calls, affinity = 0, nil
			local endpoint = "https://opencode.ai" .. path .. "/" .. row[2] .. "?tenant=one&mode=a%20b"
			check("displayed endpoint matches protocol", chat.endpointOf(record) == endpoint)
			f.h.http.handler = function(entry)
				calls = calls + 1
				check("Go path and query retained", entry.url == endpoint)
				check("selected Go key retained", headers.get(entry.headers, "Authorization") == "Bearer fixture-go-key")
				check("Go uses identifiable product UA", headers.get(entry.headers, "User-Agent") == "ProjectUAI/3.2.0")
				check("Go omits free desktop fingerprint", headers.get(entry.headers, "x-opencode-client") == nil)
				local session = headers.get(entry.headers, "x-opencode-session")
				check("stable session on both turns", session and (not affinity or session == affinity)); affinity = session
				local body = f.h.json.decode(entry.body)
				check("tools are present", body.tools and #body.tools > 0)
				if calls == 2 then check("tool result and call id replay", entry.body:find("GO_TOOL_OK", 1, true) and entry.body:find("call-go", 1, true)) end
				local output
				if row[2] == "messages" then
					output = { type = "message", role = "assistant", model = row[1],
						content = calls == 1 and { { type = "tool_use", id = "call-go", name = "fixture_lookup", input = { key = "health" } } }
							or { { type = "text", text = "GO_TOOL_OK" } }, stop_reason = calls == 1 and "tool_use" or "end_turn" }
				elseif row[2] == "responses" then
					output = { id = "resp-go", status = "completed", model = row[1], output = calls == 1
						and { { type = "function_call", call_id = "call-go", name = "fixture_lookup", arguments = '{"key":"health"}' } }
						or { { type = "message", content = { { type = "output_text", text = "GO_TOOL_OK" } } } } }
				else
					output = { choices = { { message = calls == 1 and { role = "assistant", tool_calls = {
						{ id = "call-go", type = "function", ["function"] = { name = "fixture_lookup", arguments = '{"key":"health"}' } } } }
						or { role = "assistant", content = "GO_TOOL_OK" }, finish_reason = calls == 1 and "tool_calls" or "stop" } } }
				end
				return { StatusCode = 200, Body = f.h.json.encode(output) }
			end
			local messages = { { role = "user", content = "Look up health" } }
			local first, why = f.run(function() return chat.complete(record, { messages = messages, tools = TOOLS, maxTokens = 256 }) end)
			check("tool response succeeds: " .. tostring(why), first and #first.toolCalls == 1 and first.toolCalls[1].id == "call-go")
			messages[#messages + 1] = { role = "assistant", content = first.content, toolCalls = first.toolCalls }
			messages[#messages + 1] = { role = "tool", tool_call_id = "call-go", content = "GO_TOOL_OK" }
			local final = f.run(function() return chat.complete(record, { messages = messages, tools = TOOLS, maxTokens = 256 }) end)
			check("tool result succeeds without protocol retry", final and final.content == "GO_TOOL_OK" and calls == 2)
			check("routing does not mutate saved API selection", record.api == "openai")
			f.healthy(); f.close()
		end)
	end
end
suite.case("explicit Responses endpoint and Messages header overrides survive", function()
	local f = F.new(); local chat = f.env.require("provider/chat")
	local record = recordFor(f, "https://opencode.ai/inference/go/v1/responses?tenant=one", "gpt-6-luna")
	check("Responses suffix is not doubled", chat.endpointOf(record) == "https://opencode.ai/inference/go/v1/responses?tenant=one&mode=a%20b")
	check("Responses model discovery strips suffix", f.env.require("provider/registry").endpoint(record, "/models") == "https://opencode.ai/inference/go/v1/models?tenant=one&mode=a%20b")
	f.h.http.handler = function(entry)
		check("explicit Responses path dispatches once", entry.url == "https://opencode.ai/inference/go/v1/responses?tenant=one&mode=a%20b")
		return { StatusCode = 403, Body = '{"error":{"message":"An active OpenCode Go subscription is required to use Go models."}}' }
	end
	local result, why = f.run(function() return chat.complete(record, { messages = { { role = "user", content = "hi" } } }) end)
	check("Responses preserves Go subscription refusal", not result and why:find("Check the key's workspace", 1, true) and f.h.http.requestCount == 1)
	record.model, record.baseUrl, record.authStyle = "claude-haiku-5-5", "https://opencode.ai/inference/go/v1", nil
	record.headers = { ["User-Agent"] = "FixtureGo/1", ["x-opencode-session"] = "fixture-session", Accept = "fixture/accept" }
	f.h.http.handler = function(entry)
		local get = f.env.require("net/headers").get
		check("manual Go Messages defaults to bearer", get(entry.headers, "Authorization") == "Bearer fixture-go-key" and not get(entry.headers, "x-api-key"))
		check("explicit identity and accept remain effective", get(entry.headers, "User-Agent") == "FixtureGo/1"
			and get(entry.headers, "x-opencode-session") == "fixture-session" and get(entry.headers, "Accept") == "fixture/accept")
		return { StatusCode = 200, Body = '{"type":"message","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn"}' }
	end
	check("Messages call accepted", f.run(function() return chat.complete(record, { messages = { { role = "user", content = "hi" } } }) end) ~= nil)
	f.healthy(); f.close()
end)
suite.case("Go subscription and region refusals give specific guidance without rerouting", function()
	local f = F.new(); local chat = f.env.require("provider/chat")
	local record = recordFor(f, "https://opencode.ai/zen/go/v1", "deepseek-v4.1-flash")
	local errors = {
		{ 403, "Upstream request failed: An active OpenCode Go subscription is required to use Go models.", "Check the key's workspace" },
		{ 400, "Upstream request failed: This Go model requires Global regions. Select Global in your workspace's Privacy settings to use it.", "Review this privacy choice" },
	}
	for _, item in ipairs(errors) do
		local calls = 0
		f.h.http.handler = function(entry)
			calls = calls + 1
			check("refusal uses original Go endpoint", entry.url:find("/zen/go/v1/chat/completions", 1, true))
			return { StatusCode = item[1], Body = f.h.json.encode({ error = { message = item[2] } }) }
		end
		local result, why = f.run(function() return chat.complete(record, { messages = { { role = "user", content = "hi" } } }) end)
		check("one request only", not result and calls == 1)
		check("actionable Go guidance", why:find(item[3], 1, true) and not why:find("UAI Relay app", 1, true) and not why:find("buy", 1, true))
		check("support remains idempotent", f.env.require("runtime/support").error(why) == why)
	end
	local why = f.env.require("provider/openai").errorText({ status = 410, body = '{"error":{"type":"FreeTierError","message":"OpenCode proxy endpoint has been deprecated due to upstream edge restrictions."}}' })
	check("retired proxy is not a subscription verdict", why:find("A 410 does not validate", 1, true) and not why:find("UAI Relay app", 1, true))
	f.healthy(); f.close()
end)
suite.finish()
