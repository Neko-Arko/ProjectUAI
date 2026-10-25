-- Setup copy and catalog controls reflect the actual connection and keep secrets out.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Provider setup")
local case, check = suite.case, suite.check

local function click(f, name)
	f.h.click(assert(f.h.byName(name), "missing " .. name)); f.h.settle(0.1)
end
local function typeInto(f, name, text)
	local box = assert(f.h.byName(name)):FindFirstChildOfClass("TextBox")
	box:CaptureFocus(); f.h.type(box, text); f.h.settle(0.1); return box
end

case("no-key and desktop sign-in routes explain how authentication works", function()
	for _, preset in ipairs({ "kilo", "cline" }) do
		local f = F.ui(900, 750); local registry = f.env.require("provider/registry")
		local record = registry.blank(preset)
		f.env.require("ui/panels/providers").editor(record); f.h.settle(0.2)
		local expected = preset == "cline" and "Sign in to Cline in the desktop app" or "No API key required"
		check(preset .. " does not ask for a missing API key", f.h.byName("KeyState").Text == expected)
		click(f, "ActiveModel")
		local menu = f.h.byName("Menu")
		check("setup actions are searchable", f.h.byName("MenuSearch", menu) ~= nil)
		if preset == "cline" then
			local text = f.h.textOf(menu)
			check("Cline menu names desktop catalog", text:find("Cline's free catalog through the desktop bridge", 1, true) ~= nil)
			check("Cline menu does not present virtual marker as a public route", text:find("uai-tunnel.invalid", 1, true) == nil)
		end
		check("opening setup makes no requests", f.h.http.requestCount == 0)
		f.healthy(); f.close()
	end
end)

case("route summaries and loading copy omit URL query credentials", function()
	local f = F.ui(1000, 800); local registry = f.env.require("provider/registry")
	local record = registry.blank("custom")
	record.label, record.baseUrl, record.authStyle = "Private query", "https://catalog.fixture/v1?secret=fixture-query-secret", "none"
	record.query = { token = "fixture-extra-secret" }; record.model, record.models = "manual", { "manual" }
	assert(registry.save(record)); local panel = f.env.require("ui/panels/providers").new(f.host); f.h.settle(0.2)
	local facts = f.h.textOf(f.h.byName("StatusFacts"))
	check("facts include route without secret query", facts:find("https://catalog.fixture/v1/chat/completions", 1, true) ~= nil
		and not facts:find("fixture-query-secret", 1, true) and not facts:find("fixture-extra-secret", 1, true))
	f.env.require("ui/panels/providers").editor(record); f.h.settle(0.2)
	f.h.http.handler = function() return { StatusCode = 200, delay = 1, Body = f.h.json.encode({ data = { { id = "found" } } }) } end
	click(f, "ActiveModel"); local menuText = f.h.textOf(f.h.byName("Menu"))
	check("menu hides query credentials", not menuText:find("fixture-query-secret", 1, true) and not menuText:find("fixture-extra-secret", 1, true))
	click(f, "Option_fetch"); local note = f.h.byName("ModelNote").Text
	check("loading copy names a safe route", note:find("Loading https://catalog.fixture/v1/models", 1, true) ~= nil
		and not note:find("fixture-query-secret", 1, true) and not note:find("fixture-extra-secret", 1, true))
	f.h.settle(1.2); f.env.require("ui/overlay").closeAll(); f.healthy(); f.close()
end)

case("large saved catalogs can be searched without losing focus on health updates", function()
	local f = F.ui(1000, 850); local registry = f.env.require("provider/registry")
	local record = registry.blank("custom"); record.label, record.baseUrl, record.authStyle = "Many models", "https://models.fixture/v1", "none"
	record.models = {}; for index = 1, 120 do record.models[index] = "vendor/model-" .. index end; record.model = record.models[1]
	assert(registry.save(record)); local panel = f.env.require("ui/panels/providers").new(f.host); f.h.settle(0.2)
	local row = f.h.byName("Model_12"); local search = typeInto(f, "SavedModelSearch", "model-12 vendor")
	check("only matching IDs remain", row.Visible and not f.h.byName("Model_13").Visible and f.h.byName("Model_112").Visible
		and f.h.byName("SavedModelCount").Text == "3 of 120 models")
	registry.changed:fire("health", record.id); f.h.settle(0.2)
	check("health preserves search and rows", f.h.byName("Model_12") == row and search:IsFocused()
		and f.h.byName("SavedModelSearch"):FindFirstChildOfClass("TextBox") == search)
	typeInto(f, "SavedModelSearch", "missing-id")
	check("empty result explains recovery", f.h.byName("NoSavedModelsMatch").Visible)
	panel.select(record.id); f.h.settle(0.2)
	check("selection refresh keeps search", f.h.byName("SavedModelSearch"):FindFirstChildOfClass("TextBox").Text == "missing-id"
		and f.h.byName("NoSavedModelsMatch").Visible)
	click(f, "Select_ActiveModel")
	check("active-model selector has search too", f.h.byName("MenuSearch") ~= nil)
	f.healthy(); f.close()
end)

suite.finish()
