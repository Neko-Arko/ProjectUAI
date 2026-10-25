package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Diagnostics search")
local check = suite.check
suite.case("search filters requests and log details without changing retained evidence", function()
	local h = require("env").new(); local app = assert(h.boot()); h.settle(0.3)
	local http, log = app.env.require("net/http"), app.env.require("runtime/log")
	http.history = {
		{ method = "POST", url = "https://api.fixture/v1", status = 429, ms = 5, bytes = 10, identity = "none", via = "executor", tag = "inference" },
		{ method = "GET", url = "https://other.fixture/models", status = 200, ms = 2, bytes = 20, identity = "none", via = "executor", tag = "models" },
	}
	app.app.showPanel("logs"); h.settle(0.3)
	local panel = assert(h.byName("LogsPanel", app.env.root)); local field = h.byName("DiagnosticsSearch", panel):FindFirstChildOfClass("TextBox")
	local function rows(name)
		local count = 0; for _, node in ipairs(panel:GetDescendants()) do if node.Name == name then count = count + 1 end end; return count
	end
	h.type(field, "api.fixture 429")
	check("host and status both filter requests", rows("RequestEntry") == 1 and #http.history == 2)
	h.type(field, "404")
	check("no-match state clears stale rows", rows("RequestEntry") == 0)
	h.type(field, "")
	check("clearing restores retained rows", rows("RequestEntry") == 2)
	log.clear(); log.info("provider", "request stopped", "fixture detail 503"); log.info("other", "ready")
	h.click(h.byName("Segment_log", panel)); h.type(field, "provider 503")
	check("log search includes detail fields", rows("LogEntry") == 1)
	app.env.require("runtime/caps").fn.clipboard = function() return false end
	h.click(h.byName("CopyDiagnostics", panel)); h.settle(0.1)
	check("clipboard refusal is reported", h.textOf(h.byName("CopyDiagnostics", panel)):find("Retry", 1, true) ~= nil)
	check("search produces no handler errors", #h.errors() == 0)
	app.unload()
end)
suite.finish()
