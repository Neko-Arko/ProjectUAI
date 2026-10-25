-- Model picker temperature preferences with native controls and synthetic hosts.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Model temperature UI")
local case, check = suite.case, suite.check
local function click(f, name)
	f.h.click(assert(f.h.byName(name), name)); f.h.settle(0.1)
end
local function temperature(f, mode)
	click(f, "ModelOptions"); click(f, "Option_temperature"); click(f, "Option_" .. mode)
end

case("temperature controls preserve per-model overrides and short-window scrolling", function()
	for _, width in ipairs({ 320, 900 }) do
		local f = F.ui(width, 600)
		local registry, config = f.env.require("provider/registry"), f.env.require("runtime/config")
		local record = registry.blank("custom")
		record.label, record.baseUrl, record.authStyle = "Temperature fixture", "https://temperature.fixture/v1", "none"
		record.model, record.models = "vendor/plain", { "vendor/plain", "vendor/second" }
		assert(registry.save(record)); registry.setActive(record.id)
		config.set("agent.forceSampling", { ["vendor/second"] = true })
		local picker = f.env.require("ui/panels/modelpicker").open(); f.h.settle(0.2)
		local search = f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox")
		search.Text = "vendor"; search:CaptureFocus()
		temperature(f, "omit")
		check("omit targets only the selected model", config.get("agent.forceSampling")["vendor/plain"] == false and config.get("agent.forceSampling")["vendor/second"] == true)
		check("changing sampling preserves model search", f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox") == search and search.Text == "vendor")
		temperature(f, "auto")
		check("automatic removes the override while preserving other models", config.get("agent.forceSampling")["vendor/plain"] == nil and config.get("agent.forceSampling")["vendor/second"] == true)
		temperature(f, "send")
		check("explicit send is represented by a boolean override", config.get("agent.forceSampling")["vendor/plain"] == true)
		picker.scroll.instance.AbsoluteSize = f.h.dt.Vector2.new(width - 60, 150)
		local list = f.h.byName("ModelScroll")
		check("short dialogs retain the dedicated model viewport", not picker.scroll.instance.ScrollingEnabled and list.ScrollingEnabled
			and picker.content.Size.Y.Offset == picker.scroll.viewportSize().Y and list.Size.Y.Offset > 0)
		local first = f.h.byName("Model_vendor/plain")
		check("model names retain the full detail column", f.h.byName("ModelName", first).Size.X.Scale == 1
			and f.h.byName("ModelMetadata", first).Parent == f.h.byName("ModelName", first).Parent)
		click(f, "Model_vendor/second")
		check("two-line catalog keeps selection and search stable", record.model == "vendor/second"
			and f.h.byName("Model_vendor/plain") == first and search.Text == "vendor")
		check("temperature settings occupy no permanent model-list space", f.h.byName("Section_Temperature") == nil and f.h.byName("ModelTemperature") == nil)
		picker.close(); f.h.settle(0.2); f.healthy(); f.close()
	end
end)

case("resizing compacts fixed controls while preserving focused search and model scroll", function()
	for _, width in ipairs({ 320, 900 }) do
		local f = F.ui(width, 700)
		local registry, config = f.env.require("provider/registry"), f.env.require("runtime/config")
		local record = registry.blank("custom")
		record.label, record.baseUrl, record.authStyle = "Resize fixture", "https://resize.fixture/v1", "none"
		record.model, record.models = "vendor/reasoner", { "vendor/reasoner", "vendor/free" }
		for index = 1, 12 do record.models[#record.models + 1] = "vendor/model-" .. index end
		assert(registry.save(record)); registry.setActive(record.id)
		config.set("agent.forceReasoning", { [record.model] = true })
		local picker = f.env.require("ui/panels/modelpicker").open(); f.h.settle(0.2)
		local list = f.h.byName("ModelScroll")
		local search = f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox")
		local provider, filter = f.h.byName("Section_Endpoint"), f.h.byName("FilterRow")
		local row = f.h.byName("Model_vendor/reasoner")
		search.Text = "vendor"; search:CaptureFocus()
		search.CursorPosition, search.SelectionStart = 4, 2
		list.CanvasPosition = f.h.dt.Vector2.new(0, 90)
		for _, height in ipairs({ 440, 235, 150, 105 }) do
			picker.scroll.instance.AbsoluteSize = f.h.dt.Vector2.new(width - 60, height)
			local room = picker.scroll.viewportSize().Y
			check("only the catalog scrolls at body height " .. height, not picker.scroll.instance.ScrollingEnabled and list.ScrollingEnabled)
			check("the catalog fits the available body at height " .. height, list.Size.Y.Offset > 0
				and list.Position.Y.Offset + list.Size.Y.Offset <= room and picker.content.Size.Y.Offset == room)
			check("provider and search remain fixed and usable at height " .. height, provider.Visible and filter.Visible
				and provider.Position.Y.Offset + provider.Size.Y.Offset <= list.Position.Y.Offset
				and filter.Position.Y.Offset + filter.Size.Y.Offset <= list.Position.Y.Offset)
			check("resize retains focused field and scroll at height " .. height, search:IsFocused() and search.Text == "vendor"
				and search.CursorPosition == 4 and search.SelectionStart == 2
				and f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox") == search
				and f.h.byName("Model_vendor/reasoner") == row and list.CanvasPosition.Y == 90)
		end
		picker.scroll.instance.AbsoluteWindowSize = f.h.dt.Vector2.new(width - 64, 100)
		list.AbsoluteCanvasSize = f.h.dt.Vector2.new(width - 68, 1200)
		check("native viewport and canvas measurements preserve search and scrolling", list.Position.Y.Offset + list.Size.Y.Offset == picker.scroll.viewportSize().Y
			and search:IsFocused() and search.CursorPosition == 4 and search.SelectionStart == 2 and list.CanvasPosition.Y == 90)
		picker.scroll.instance.AbsoluteWindowSize = f.h.dt.Vector2.new(0, 0)
		check("short views remove optional chrome from the model viewport", not f.h.byName("Section_ReasoningEffort").Visible
			and not f.h.byName("CurrentSelection").Visible and not f.h.byName("ModelCount").Visible
			and not f.h.byName("FreeOnly").Visible)
		click(f, "ModelOptions"); click(f, "Option_effort"); click(f, "Option_high")
		check("compact effort menu writes the same global preference", config.get("agent.effort") == "high" and list.CanvasPosition.Y == 90)
		click(f, "ModelOptions"); click(f, "Option_free")
		check("compact free filter uses the existing catalog", f.h.byName("Model_vendor/free").Visible
			and not f.h.byName("Model_vendor/reasoner").Visible and search.Text == "vendor")
		click(f, "ModelOptions"); click(f, "Option_free")
		search:CaptureFocus()
		picker.scroll.instance.AbsoluteSize = f.h.dt.Vector2.new(width - 60, 440)
		check("expanding restores optional chrome without replacing controls", f.h.byName("Section_ReasoningEffort").Visible
			and f.h.byName("FreeOnly").Visible and f.h.byName("CurrentSelection").Visible
			and search:IsFocused() and list.CanvasPosition.Y == 90 and f.h.byName("Model_vendor/reasoner") == row)
		picker.close(); f.h.settle(0.2); f.healthy(); f.close()
	end
end)

suite.finish()
