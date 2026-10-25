-- The packaged client must avoid constructing hidden details for every tool.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Tool panel")
local check = suite.check
suite.case("details are lazy and search spans tool names and groups", function()
	local h = require("env").new(); local app = assert(h.boot()); h.settle(0.3)
	local schema = app.env.require("agent/schema"); local describe = schema.describe
	local count = 0
	schema.describe = function(value) count = count + 1; return describe(value) end
	app.app.showPanel("tools"); h.settle(0.3)
	check("collapsed tools allocate no parameter descriptions", count == 0)
	local panel = assert(h.byName("ToolsPanel", app.env.root))
	local field = h.byName("ToolSearch", panel):FindFirstChildOfClass("TextBox")
	h.type(field, "file read")
	local row = assert(h.byName("file_read", panel))
	check("query matches separated words", h.byName("ToolSearchCount", panel).Text:find("matching tool", 1, true) ~= nil)
	local button = h.byName("ToolDetailsToggle", row)
	h.click(button); h.settle(0.2)
	check("opening a tool describes only that schema", count == 1 and h.byName("ToolDetails", row).Visible)
	h.click(button); h.click(button); h.settle(0.2)
	check("reopening reuses the description", count == 1)
	h.click(h.byName("Segment_deny", row)); h.settle(0.2)
	check("lazy permissions still update the real rule", app.env.require("agent/permissions").ruleFor("file_read") == "deny")
	h.type(field, "not a real tool query")
	check("empty searches do not leave stale tool cards", h.byName("file_read", panel) == nil)
	check("no hidden UI handler failures", #h.errors() == 0)
	app.unload()
end)
suite.finish()
