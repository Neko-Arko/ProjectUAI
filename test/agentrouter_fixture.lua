-- Synthetic AgentRouter transport; credentials and Roblox data are fixtures.
local F = require("workspace_fixture")
local M = { suite = F.suite }
function M.new()
	local f = F.new()
	f.registry = f.env.require("provider/registry")
	f.record = f.registry.blank("agentrouter")
	f.record.id, f.record.model, f.record.apiKey = "agentrouter-fixture", "gpt-6.1-sol", "fixture-key"
	f.chat = f.env.require("provider/chat")
	f.responses = f.env.require("provider/responses")
	f.sent = {}
	function f.reply(text)
		return { StatusCode = 200, Body = f.h.json.encode({ object = "response", status = "completed", model = f.record.model,
			output = { { type = "message", role = "assistant", content = { { type = "output_text", text = text or "fixture complete" } } } } }) }
	end
	function f.handler(callback)
		f.h.http.handler = function(entry)
			f.sent[#f.sent + 1] = entry
			return callback(entry, #f.sent)
		end
	end
	function f.complete(options, seconds)
		options = options or {}
		options.messages = options.messages or { { role = "user", content = "Inspect the fixture" } }
		options.attempts, options.timeout = options.attempts or 1, options.timeout or 5
		return f.run(function() return f.chat.complete(f.record, options) end, seconds or 0.3)
	end
	function f.finish() f.healthy(); f.close() end
	return f
end
return M
