-- Model picker temperature preferences with native controls and synthetic hosts.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Model temperature UI")
local case, check = suite.case, suite.check
local function click(f, name)
	f.h.click(assert(f.h.byName(name), name)); f.h.settle(0.1)
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
		click(f, "ModelTemperature"); click(f, "Option_omit")
		check("omit targets only the selected model", config.get("agent.forceSampling")["vendor/plain"] == false and config.get("agent.forceSampling")["vendor/second"] == true)
		check("changing sampling preserves model search", f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox") == search and search.Text == "vendor")
		click(f, "ModelTemperature"); click(f, "Option_auto")
		check("automatic removes the override while preserving other models", config.get("agent.forceSampling")["vendor/plain"] == nil and config.get("agent.forceSampling")["vendor/second"] == true)
		click(f, "ModelTemperature"); click(f, "Option_send")
		check("explicit send is represented by a boolean override", config.get("agent.forceSampling")["vendor/plain"] == true)
		picker.scroll.instance.AbsoluteSize = f.h.dt.Vector2.new(width - 60, 150)
		local list = f.h.byName("ModelScroll")
		check("short dialogs scroll the full controls with one owner", picker.scroll.instance.ScrollingEnabled and not list.ScrollingEnabled and picker.content.Size.Y.Offset > 150)
		check("temperature controls remain inside scrollable content", f.h.byName("Section_Temperature").Parent == f.h.byName("ModelPicker"))
		picker.close(); f.h.settle(0.2); f.healthy(); f.close()
	end
end)

suite.finish()
