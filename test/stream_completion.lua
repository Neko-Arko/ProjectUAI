-- Buffered completion markers, truncation diagnostics and protocol mismatches.
-- Synthetic provider responses only; never sends network requests.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Stream completion")
local case, check = suite.case, suite.check
local function has(value, part) return tostring(value):find(part, 1, true) ~= nil end
local function fixture()
	local f = F.new()
	function f.event(value, eventName)
		return (eventName and ("event: " .. eventName .. "\n") or "") .. "data: " .. f.h.json.encode(value) .. "\n\n"
	end
	f.parsers = {
		chat = { label = "Chat Completions", marker = "[DONE] or finish_reason", parse = f.env.require("net/sse").parse },
		anthropic = { label = "Anthropic Messages", marker = "message_stop or stop_reason", parse = f.env.require("provider/anthropic").parseStream },
		responses = { label = "Responses", marker = "response.completed", parse = f.env.require("provider/responses").parse },
	}
	f.partial = {
		chat = f.event({ choices = { { delta = { reasoning_content = "Thinking" } } } }),
		anthropic = f.event({ type = "content_block_delta", index = 0, delta = { type = "thinking_delta", thinking = "Thinking" } }),
		responses = f.event({ type = "response.output_text.delta", delta = "Partial answer" }),
		gemini = f.event({ candidates = { { content = { parts = { { text = "Partial answer" } } } } } }),
	}
	return f
end

case("completed streams accept their marker at EOF and compatible final reasons", function()
	local f = fixture()
	local chat = f.parsers.chat.parse
	local part = f.event({ choices = { { delta = { content = "Ready" } } } })
	check("DONE needs no final blank line", chat(part .. "data: [DONE]").streamError == nil)
	local final = f.event({ choices = { { delta = {}, finish_reason = "stop" } } }):gsub("\n\n$", "")
	local parsed = chat(part .. final)
	check("a finish reason can replace DONE", not parsed.streamError and parsed.content == "Ready" and parsed.finish == "stop")
	local messages = f.parsers.anthropic.parse
	local text = f.event({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "Ready" } })
	parsed = messages(text .. f.event({ type = "message_stop" }):gsub("\n\n$", ""))
	check("Messages final event flushes at EOF", not parsed.streamError and parsed.content == "Ready")
	parsed = messages(text .. f.event({ type = "message_delta", delta = { stop_reason = "end_turn" } }))
	check("Messages final reason can replace message_stop", not parsed.streamError and parsed.finish == "stop")
	local response = f.event({ response = { status = "completed", output = {
		{ type = "message", content = { { type = "output_text", text = "Ready" } } },
	} } }, "response.completed"):gsub("\n\n$", "")
	for _, newline in ipairs({ "\n", "\r", "\r\n" }) do
		parsed = f.parsers.responses.parse(": heartbeat\n\n" .. response:gsub("\n", newline))
		check("Responses uses event metadata and EOF for " .. string.format("%q", newline), not parsed.streamError and parsed.content == "Ready")
	end
	f.healthy(); f.close()
end)

case("partial thinking and complete tool JSON still need a completion marker", function()
	local f = fixture(); local http = f.env.require("net/http")
	for protocol, parser in pairs(f.parsers) do
		local parsed = parser.parse(f.partial[protocol])
		check(protocol .. " preserves the terminal prefix", has(parsed.streamError, "malformed_stream: stream ended before completion;"))
		check(protocol .. " names its missing marker", has(parsed.streamError, "missing " .. parser.marker))
		check(protocol .. " failure cannot be retried", http.terminal(parsed.streamError))
	end
	local body = f.event({ choices = { { delta = { tool_calls = {
		{ index = 0, id = "pending", ["function"] = { name = "fixture_tool", arguments = '{"value":1}' } },
	} } } } })
	local parsed = f.parsers.chat.parse(body)
	check("a fully formed call does not prove the stream completed", #parsed.toolCalls == 1 and parsed.streamError ~= nil)
	f.healthy(); f.close()
end)

case("recognizable wrong protocols receive configuration guidance", function()
	local f = fixture()
	local labels = { chat = "Chat Completions", anthropic = "Anthropic Messages", responses = "Responses", gemini = "Google Gemini" }
	for expected, parser in pairs(f.parsers) do
		for actual, body in pairs(f.partial) do
			if expected ~= actual then
				local parsed = parser.parse(body)
				check(expected .. " identifies " .. actual, has(parsed.streamError, "received " .. labels[actual] .. " events while expecting " .. parser.label))
				check(expected .. " explains what to check for " .. actual, has(parsed.streamError, "provider Protocol and Base URL"))
			end
		end
	end
	f.healthy(); f.close()
end)

case("optional vendor metadata cannot turn a valid stream into a mismatch", function()
	local f = fixture()
	local unrelated = f.event({ type = "response.vendor_metric", delta = "extra" })
	local foreign = f.partial.gemini
	local finals = {
		chat = "data: [DONE]\n\n",
		anthropic = f.event({ type = "message_stop" }),
		responses = f.event({ type = "response.completed", response = { status = "completed" } }),
	}
	for protocol, parser in pairs(f.parsers) do
		local parsed = parser.parse(unrelated .. foreign .. f.partial[protocol] .. finals[protocol])
		check(protocol .. " accepts metadata with a completed selected stream", not parsed.streamError)
		parsed = parser.parse(foreign .. f.partial[protocol])
		check(protocol .. " recognizes selected events before diagnosing truncation", has(parsed.streamError, "missing " .. parser.marker) and not has(parsed.streamError, "received "))
		parsed = parser.parse(unrelated)
		check(protocol .. " ignores unknown vendor type for protocol identification", has(parsed.streamError, "missing " .. parser.marker))
	end
	f.healthy(); f.close()
end)

case("provider failure details take priority over completion diagnostics", function()
	local f = fixture()
	local errorFrame = f.event({ error = { code = "upstream_failed", message = "Provider stopped this request" } })
	for protocol, parser in pairs(f.parsers) do
		local parsed = parser.parse(f.partial[protocol] .. errorFrame .. "data: [DONE]\n\n")
		check(protocol .. " retains provider reason", has(parsed.streamError, "upstream_failed") and has(parsed.streamError, "Provider stopped this request"))
		check(protocol .. " does not replace provider reason with marker guidance", not has(parsed.streamError, "missing "))
	end
	f.healthy(); f.close()
end)

case("buffered truncated replies settle once without a provider retry", function()
	for _, protocol in ipairs({ "chat", "anthropic" }) do
		local f = fixture(); local calls, retries = 0, 0
		local record = f.env.require("provider/registry").blank("custom")
		record.id, record.label, record.model = "truncated", "Truncated fixture", "fixture-model"
		record.baseUrl, record.authStyle, record.api = "https://fixture.test/v1", "none", protocol == "chat" and "openai" or "anthropic"
		f.h.http.handler = function()
			calls = calls + 1
			return { StatusCode = 200, Headers = { ["Content-Type"] = "text/event-stream" }, Body = f.partial[protocol] }
		end
		local result, why = f.run(function()
			return f.env.require("provider/chat").complete(record, { messages = { { role = "user", content = "Hello" } },
				stream = true, attempts = 3, onRetry = function() retries = retries + 1 end })
		end)
		check(protocol .. " fails with the named marker", not result and has(why, "missing " .. f.parsers[protocol].marker))
		check(protocol .. " sends once and never schedules a repair retry", calls == 1 and retries == 0)
		f.healthy(); f.close()
	end
end)

suite.finish()
