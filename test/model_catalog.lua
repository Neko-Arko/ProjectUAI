-- Public mixed catalogs are filtered by documented API kind, never model names.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Model catalog compatibility")
local case, check = suite.case, suite.check

case("exact documented schemas omit media and incompatible protocol entries", function()
	local f = F.new(); local catalog = f.env.require("provider/model_catalog")
	local routes = {
		{ "https://api.aimlapi.com/v1/models", "type", "openai/chat-completions", "anthropic/messages" },
		{ "https://ai-gateway.vercel.sh/v1/models", "type", "language", "embedding" },
		{ "https://api.friendli.ai/serverless/v1/models", "mode", "chat", "embedding" },
		{ "https://api.venice.ai/api/v1/models", "type", "text", "image" },
	}
	for _, route in ipairs(routes) do
		check("chat kept on " .. route[1], catalog.accepts(route[1], { id = "chat", [route[2]] = route[3] }))
		check("non-chat omitted on " .. route[1], not catalog.accepts(route[1], { id = "chat", [route[2]] = route[4] }))
		check("untyped IDs preserved", catalog.accepts(route[1], { id = "embedding-in-name" }) and catalog.accepts(route[1], "image-name"))
		check("unknown field shape preserved", catalog.accepts(route[1], { id = "model", [route[2]] = { route[4] } }))
	end
	for _, kind in ipairs({ "openai/responses/submit", "openai/image-generation", "audio", "video", "embedding" }) do
		check("AI/ML incompatible API " .. kind, not catalog.accepts(routes[1][1], { id = "model", type = kind }))
	end
	f.healthy(); f.close()
end)

case("schema interpretation does not escape its exact origin and path", function()
	local f = F.new(); local catalog = f.env.require("provider/model_catalog")
	for _, url in ipairs({ "https://api.aimlapi.com.evil.test/v1/models", "https://fixture.test/v1/models",
		"http://api.aimlapi.com/v1/models", "https://api.aimlapi.com:8443/v1/models", "https://api.aimlapi.com/proxy/v1/models",
		"https://api.aimlapi.com/v1/modelsextra", "https://api.aimlapi.com/other/models", "not a URL" }) do
		check("generic catalog is preserved " .. url, catalog.accepts(url, { id = "custom", type = "anthropic/messages" }))
	end
	check("public route with query still has documented kinds", not catalog.accepts("https://api.aimlapi.com/v1/models?locale=en", { id = "image", type = "image" }))
	check("host casing has no semantic effect", not catalog.accepts("https://API.AIMLAPI.COM/v1/models", { id = "image", type = "image" }))
	f.healthy(); f.close()
end)

case("discovery reports omissions and preserves explicit manual choices", function()
	local f = F.new(); local registry = f.env.require("provider/registry"); local models = f.env.require("provider/models")
	local record = registry.blank("aimlapi"); record.apiKey = "fixture-key"
	record.models = { "manual-image-name" }; record.model = record.models[1]
	f.h.http.handler = function() return { StatusCode = 200, Body = f.h.json.encode({ data = {
		{ id = "chat-one", type = "openai/chat-completions" }, { id = "chat-one", type = "openai/chat-completions" },
		{ id = "image-one", type = "image" }, { id = "responses-one", type = "openai/responses/submit" },
		{ id = "future-untyped" },
	} }) } end
	local found, note = f.run(function() return models.discover(record) end)
	check("only compatible and untyped discovery IDs", #found == 2 and found[1] == "chat-one" and found[2] == "future-untyped")
	check("omissions are visible", tostring(note):find("2 non-chat entries hidden", 1, true) ~= nil)
	local merged = models.list(record)
	check("manual ID remains first and selected", #merged == 3 and merged[1] == "manual-image-name" and record.model == "manual-image-name")
	check("discovery stays separate from manual persistence", #record.models == 1)
	check("listing does not infer a model is free", not models.isFree(record, "chat-one"))
	f.healthy(); f.close()
end)

case("a catalog containing only incompatible entries gives an actionable result", function()
	local f = F.new(); local registry = f.env.require("provider/registry"); local models = f.env.require("provider/models")
	local record = registry.blank("vercel"); record.apiKey = "fixture-key"
	f.h.http.handler = function() return { StatusCode = 200, Body = f.h.json.encode({ data = { { id = "image", type = "image" } } }) } end
	local found, note = f.run(function() return models.discover(record) end)
	check("no wrong-protocol model is offered", #found == 0)
	check("diagnostic distinguishes incompatible from empty catalog", tostring(note):find("no compatible chat models", 1, true) ~= nil)
	f.healthy(); f.close()
end)

suite.finish()
