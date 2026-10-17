-- Regression for the reported 163-tools / maximum-length-128 refusal.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Provider tool count")
local case, check = suite.case, suite.check
local function setup()
	local f = F.new()
	local registry = f.env.require("provider/registry")
	local record = registry.blank("custom")
	record.id, record.label, record.model = "tool-count", "Tool count fixture", "unknown-model"
	record.baseUrl, record.apiKey = "https://fixture.test/v1", "fixture-key"
	assert(registry.save(record, { force = true }))
	local tools = {}
	for index = 1, 163 do tools[index] = { type = "function", ["function"] = {
		name = "fixture_" .. index, parameters = { type = "object", properties = {} } } } end
	return f, record, tools
end

case("unknown models and explicit overrides stay within the wire ceiling", function()
	local f, record, tools = setup()
	local openai = f.env.require("provider/openai")
	for _, adapter in ipairs({ openai, f.env.require("provider/responses") }) do
		local wire = adapter.toolsFor and adapter.toolsFor(tools) or tools
		for _, request in ipairs({ { tools = tools }, { tools = tools, extra = { tools = wire } } }) do
			local body = adapter.buildBody(record, request)
			check("163 supplied tools produce at most 128 declarations", #body.tools == 128)
			check("wire shape and first declaration survive", (body.tools[1]["function"] or body.tools[1]).name == "fixture_1")
		end
		record.params = { tools = wire }
		check("provider parameters cannot bypass the ceiling", #adapter.buildBody(record, {}).tools == 128)
		record.params = nil
	end
	check("caller catalogue remains complete and unmodified", #tools == 163 and tools[163]["function"].name == "fixture_163")
	local message = "Bad request: Invalid 'tools': array too long. Expected an array with maximum length 128, but got an array with length 163 instead."
	check("reported wording extracts the maximum rather than the sent count", openai.toolCeilingFromMessage(message) == 128)
	local body = { tools = tools }
	local note, key = openai.repairForTest(body, message)
	check("existing oversized bodies repair to the stated limit", note and key == "cap_tools" and #body.tools == 128)
	f.healthy(); f.close()
end)

case("a stricter provider refusal retries once and persists its scoped limit", function()
	local f, record, tools = setup()
	local counts = {}
	f.h.http.handler = function(req)
		counts[#counts + 1] = #f.h.json.decode(req.body).tools
		if #counts == 1 then return { StatusCode = 400, Body = f.h.json.encode({ error = { message =
			"Invalid 'tools': array too long. Expected an array with maximum length 64, but got an array with length 128 instead." } }) } end
		return { StatusCode = 200, Body = f.h.json.encode({ choices = { { message = { content = "ok" }, finish_reason = "stop" } } }) }
	end
	local adapter = f.env.require("provider/openai")
	local request = { messages = { { role = "user", content = "fixture" } }, tools = tools, stream = false }
	local result = f.run(function() return adapter.complete(record, request) end)
	check("explicit smaller limit recovers the rejected request", result and result.content == "ok" and #counts == 2 and counts[1] == 128 and counts[2] == 64)
	local again = f.run(function() return adapter.complete(record, request) end)
	check("next request uses the learned limit immediately", again and counts[3] == 64 and record.toolsCap.limit == 64)
	check("learning does not trim the registered catalogue", #tools == 163)
	f.healthy(); f.close()
end)

suite.finish()
