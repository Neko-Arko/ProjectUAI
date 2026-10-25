-- Touch-only boots use the real handheld metrics from the shipped bundle.
-- Bounds are synthetic native geometry, not a claim about Roblox raster output.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local passed = 0
local function check(name, value) assert(value, name); passed = passed + 1 end

for _, size in ipairs({ { 320, 640 }, { 844, 390 } }) do
	local h = envMock.new()
	local uis = h.services.UserInputService
	uis.TouchEnabled, uis.MouseEnabled, uis.KeyboardEnabled = true, false, false
	h.setViewport(size[1], size[2])
	local app = assert(h.boot()); h.settle(0.5)
	local record = app.providers.blank("custom")
	record.label, record.baseUrl, record.authStyle = "Touch fixture", "https://touch.fixture/v1", "none"
	record.model, record.models = "claude-opus-5", { "claude-opus-5" }
	for index = 2, 12 do record.models[index] = "fixture-" .. index .. "-free" end
	assert(app.providers.save(record)); app.providers.setActive(record.id)
	local windowPosition, windowSize = app.app.window.root.Position, app.app.window.root.Size
	local picker = app.env.require("ui/panels/modelpicker").open(); h.settle(0.3)
	check("picker leaves the main window's placement intact", app.app.window.root.Position == windowPosition and app.app.window.root.Size == windowSize)
	check("picker is inside the physical viewport", picker.card.AbsolutePosition.X >= 0 and picker.card.AbsolutePosition.Y >= 0
		and picker.card.AbsolutePosition.X + picker.card.AbsoluteSize.X <= size[1]
		and picker.card.AbsolutePosition.Y + picker.card.AbsoluteSize.Y <= size[2])
	check("portrait picker can use more than the old compact height", size[2] < 500 or picker.card.AbsoluteSize.Y > 400)
	for _, name in ipairs({ "Section_Endpoint", "FreeOnly", "Model_claude-opus-5", "Effort_low", "FetchModels", "ModelOptions", "PickerDone", "Close" }) do
		local node = assert(h.byName(name, picker.card), name)
		check(name .. " has a 40px touch target", node.AbsoluteSize.X >= 40 and node.AbsoluteSize.Y >= 40)
	end
	local search = h.byName("ModelFilter", picker.card)
	check("model search has a 40px touch target", search.AbsoluteSize.Y >= 40)
	for _, node in ipairs(picker.card:GetDescendants()) do
		if (node:IsA("TextLabel") or node:IsA("TextBox")) and node.Text ~= "" then check("text respects the handheld reading floor", node.TextSize >= 10) end
	end
	local list = h.byName("ModelScroll", picker.card)
	check("only one vertical scroll owns the model body", picker.scroll.instance.ScrollingEnabled ~= list.ScrollingEnabled)
	uis.OnScreenKeyboardSize, uis.OnScreenKeyboardVisible = h.dt.Vector2.new(size[1], math.floor(size[2] * 0.55)), true
	uis:GetPropertyChangedSignal("OnScreenKeyboardVisible"):Fire(); h.settle(0.3)
	check("keyboard keeps one scrolling owner", picker.scroll.instance.ScrollingEnabled and not list.ScrollingEnabled)
	local effort = h.byName("Section_ReasoningEffort", picker.card)
	check("effort remains inside scrollable content", effort:IsDescendantOf(picker.content) and effort.Visible)
	-- The mock does not populate ScrollingFrame.AbsoluteCanvasSize. Derive the
	-- native automatic canvas extent from the actual assigned body bounds.
	local verticalEnd = math.max(0, picker.content.Size.Y.Offset - picker.scroll.viewportSize().Y)
	picker.scroll.instance.CanvasPosition = h.dt.Vector2.new(0, verticalEnd); h.settle(0.1)
	check("the complete body has a reachable scroll end", verticalEnd > 0 and picker.scroll.instance.CanvasPosition.Y == verticalEnd)
	h.click(h.byName("Effort_high", picker.card)); h.settle(0.1)
	check("scrolling to effort changes the real preference", app.config.get("agent.effort") == "high")
	local pills = h.byName("EffortPills", picker.card)
	local width, count = 0, 0
	local primitives, theme = app.env.require("ui/primitives"), app.env.require("ui/theme")
	for _, child in ipairs(pills:GetChildren()) do
		if child:IsA("GuiButton") then
			local natural = primitives.measureText(h.textOf(child), { role = "small" }).X + theme.space.md * 2 + theme.space.sm
			width = width + math.max(child.AbsoluteSize.X, natural); count = count + 1
		end
	end
	width = width + math.max(0, count - 1) * pills:FindFirstChildOfClass("UIListLayout").Padding.Offset
	pills.CanvasPosition = h.dt.Vector2.new(math.max(0, width - pills.AbsoluteSize.X), 0)
	check("effort choices scroll horizontally when wider than the picker", pills.ScrollingEnabled and pills.ScrollingDirection == h.sandbox.Enum.ScrollingDirection.X
		and (width <= pills.AbsoluteSize.X or pills.CanvasPosition.X > 0))
	h.click(h.byName("Effort_off", picker.card)); h.settle(0.1)
	check("the final horizontally scrollable effort choice works", app.config.get("agent.effort") == "off")
	h.click(h.byName("ModelOptions", picker.card)); h.settle(0.1)
	check("custom model entry remains available", h.byName("Option_add") ~= nil)
	h.click(h.byName("Option_add")); h.settle(0.1)
	check("custom model prompt opens above the picker", h.byName("PromptField") ~= nil)
	local surfaces = app.env.require("ui/overlay").open
	surfaces[#surfaces].close(); h.settle(0.2)
	uis.OnScreenKeyboardVisible = false; uis:GetPropertyChangedSignal("OnScreenKeyboardVisible"):Fire(); h.settle(0.3)
	h.click(h.byName("Section_Endpoint", picker.card)); h.settle(0.3)
	local switcher = app.env.require("ui/panels/providerpicker").open(picker)
	for _, name in ipairs({ "ProviderSwitchSearch", "ManageSavedProviders", "Close" }) do
		local node = assert(h.byName(name, switcher.card), name)
		check("provider " .. name .. " has a 40px touch target", node.AbsoluteSize.X >= 40 and node.AbsoluteSize.Y >= 40)
	end
	picker.close(); h.settle(0.3)
	check("touch picker releases callbacks without errors", #h.errors() == 0 and #h.instanceState.typeErrors == 0)
	app.unload()
end

print("Model picker touch: " .. passed .. " checks passed")
