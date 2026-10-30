package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Tool discovery")
local check = suite.check
suite.case("ranked discovery avoids schema work and respects live scope", function()
	local f = F.new(); local registry = f.tools({ "tool_search" })
	for _, item in ipairs({ { "fixture_read", "Read a source workspace" }, { "fixture_other", "fixture read workspace" } }) do
		registry.register({ name = item[1], description = item[2], risk = "read", group = "fs",
			parameters = { type = "object", properties = { options = { type = "object", properties = {} } } }, run = function() return "ok" end })
	end
	local built, original = 0, registry.definition
	registry.definition = function(tool) built = built + 1; return original(tool) end
	local listed = f.dispatch("tool_search", { action = "list", query = "fixture read" })
	check("exact name is ranked first", listed.ok and listed.text:find("1. fixture_read", 1, true) ~= nil)
	check("listing does not materialize every schema", built == 0)
	local described = f.dispatch("tool_search", { action = "describe", name = "fixture_read", limit = 1000 })
	check("schema page accepts useful byte limits", described.ok and built == 1)
	check("empty property maps match wire JSON objects", described.text:find('"properties":{}', 1, true) ~= nil)
	f.env.require("agent/permissions").setRule("fixture_read", "deny")
	local denied = f.dispatch("tool_search", { action = "describe", name = "fixture_read" })
	check("new permission rules take effect immediately", not denied.ok)
	registry.setGroupEnabled("fs", false)
	check("disabled tools disappear without a stale discovery cache", #registry.available({ only = { fixture_other = true } }) == 0)
	f.healthy(); f.close()
end)
suite.finish()
