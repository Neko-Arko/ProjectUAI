-- Native picker geometry and style contracts. The synthetic host measures the
-- assigned bounds and row layout; it does not reproduce Roblox raster rendering.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Model picker layout")
local case, check = suite.case, suite.check

local function fixture(width, height)
	local f = F.ui(width, height)
	local registry, config = f.env.require("provider/registry"), f.env.require("runtime/config")
	local record = registry.blank("custom")
	record.label, record.baseUrl, record.authStyle = "Picker fixture", "https://picker.fixture/v1", "none"
	record.model, record.models = "deepseek-v4.1-flash-free", { "deepseek-v4.1-flash-free" }
	for index = 2, 8 do record.models[index] = "fixture-" .. index .. "-free" end
	assert(registry.save(record)); registry.setActive(record.id)
	config.set("agent.forceReasoning", { [record.model] = true, [record.models[2]] = true })
	config.set("agent.forceSampling", { [record.model] = true })
	config.set("agent.temperature", 0.7)
	f.record, f.registry, f.config = record, registry, config
	return f
end

local function click(f, name)
	f.h.click(assert(f.h.byName(name), "missing control: " .. name)); f.h.settle(0.2)
end

local function modelRows(list)
	local rows = {}
	for _, node in ipairs(list:GetChildren()) do
		if node:IsA("TextButton") and node.Visible then rows[#rows + 1] = node end
	end
	table.sort(rows, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	return rows
end

local function fullRows(list)
	local pad = assert(list:FindFirstChildOfClass("UIPadding"))
	local gap = assert(list:FindFirstChildOfClass("UIListLayout")).Padding.Offset
	local used, visible = pad.PaddingTop.Offset, 0
	for _, row in ipairs(modelRows(list)) do
		used = used + (visible > 0 and gap or 0) + row.Size.Y.Offset
		if used + pad.PaddingBottom.Offset > list.Size.Y.Offset then break end
		visible = visible + 1
	end
	return visible
end

local function marked(rows)
	local checks, fills = 0, 0
	for _, row in ipairs(rows) do
		local mark = assert(row:FindFirstChild("IconSlot", true))
		if mark.Visible then checks = checks + 1 end
		if row.BackgroundTransparency == 0 then fills = fills + 1 end
	end
	return checks == 1 and fills == 1
end

local function subdued(stroke, theme, surface)
	return stroke.Thickness == 1 and stroke.Transparency == 0
		and stroke.Color.G > surface.G and stroke.Color.G < theme.color.success.G * 0.8
		and stroke.Color.G > stroke.Color.R and stroke.Color.G > stroke.Color.B
end

case("screenshot viewport fits three complete rows with reasoning and quiet free outlines", function()
	local f = fixture(777, 632)
	local theme = f.env.require("ui/theme")
	local picker = f.env.require("ui/panels/modelpicker").open(); f.h.settle(0.3)
	local list, effort = assert(f.h.byName("ModelScroll")), assert(f.h.byName("Section_ReasoningEffort"))
	local rows = modelRows(list)
	check("dialog stays bounded with its provider context", picker.card.Size.X.Offset <= 540 and picker.card.Size.Y.Offset <= 560)
	check("three complete rows fit with the reasoning controls shown", effort.Visible and #rows == 8 and fullRows(list) >= 3)
	check("the active provider and model are visible above search", f.h.byName("CurrentProvider").Text == "Picker fixture"
		and f.h.byName("CurrentModel").Text == f.record.model and f.h.byName("CurrentProviderStatus").Text:find("8 free", 1, true))
	check("the catalogue owns scrolling at the screenshot size", list.ScrollingEnabled and not picker.scroll.instance.ScrollingEnabled)
	check("the list stops before reasoning controls", list.AbsolutePosition.Y + list.AbsoluteSize.Y < effort.AbsolutePosition.Y)
	check("temperature consumes no permanent list space", f.h.byName("Section_Temperature") == nil and f.h.byName("ModelTemperature") == nil)
	check("manual effort support is identified", assert(f.h.byName("EffortLabel")).Text:find("manual", 1, true) ~= nil)
	for _, row in ipairs(rows) do
		local stroke = assert(row:FindFirstChildOfClass("UIStroke"))
		check("free models retain a muted one-pixel green outline", subdued(stroke, theme, theme.color.surface))
		check("rounded outlines have clear separation", row:FindFirstChildOfClass("UICorner").CornerRadius.Offset > 0
			and list:FindFirstChildOfClass("UIListLayout").Padding.Offset > stroke.Thickness * 2)
	end
	check("one checkmark and filled row identify selection", marked(rows))
	local selected, search = rows[2], f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox")
	click(f, selected.Name)
	check("selection changes the model in place", f.registry.active().model == f.record.models[2]
		and f.h.byName(selected.Name) == selected and marked(rows) and selected:FindFirstChild("IconSlot", true).Visible)
	check("model selection preserves the search instance", f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox") == search)
	selected.SelectionGained:Fire(); f.h.settle(0.2)
	check("keyboard focus remains distinct from the free marker", selected:FindFirstChildOfClass("UIStroke").Color == theme.color.accent)
	selected.SelectionLost:Fire(); f.h.settle(0.2)
	check("losing focus restores the quiet free outline", subdued(selected:FindFirstChildOfClass("UIStroke"), theme, theme.color.surface))
	picker.close(); f.h.settle(0.3); f.healthy(); f.close()
end)

case("short touch layouts keep one scroll owner and temperature under Options", function()
	local f = fixture(320, 400)
	f.h.services.UserInputService.TouchEnabled = true
	f.env.require("ui/responsive").refresh("picker fixture")
	local picker = f.env.require("ui/panels/modelpicker").open(); f.h.settle(0.3)
	local list, search = assert(f.h.byName("ModelScroll")), f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox")
	check("short screens keep the catalogue as the scrolling owner", not picker.scroll.instance.ScrollingEnabled and list.ScrollingEnabled
		and picker.content.Size.Y.Offset == picker.scroll.viewportSize().Y)
	check("touch rows keep the shared input target minimum", modelRows(list)[1].Size.Y.Offset >= f.env.require("ui/responsive").minTarget())
	local effort = assert(f.h.byName("Section_ReasoningEffort"))
	check("short screens keep reasoning levels visible below the catalogue", effort.Visible and f.h.byName("EffortPills").Visible
		and list.AbsoluteSize.Y > 0 and list.AbsolutePosition.Y + list.AbsoluteSize.Y < effort.AbsolutePosition.Y
		and effort.AbsolutePosition.Y + effort.AbsoluteSize.Y <= picker.footer.AbsolutePosition.Y)
	search.Text = "free"
	click(f, "ModelOptions")
	local temperature = assert(f.h.byName("Option_temperature"))
	check("Options exposes temperature and the current policy", f.h.textOf(temperature):find("Temperature", 1, true) ~= nil
		and f.h.textOf(temperature):find("Send", 1, true) ~= nil and f.h.textOf(temperature):find("0.7", 1, true) ~= nil)
	click(f, "Option_temperature")
	check("temperature modes and the shared value remain accessible", f.h.byName("Option_auto") ~= nil
		and f.h.byName("Option_send") ~= nil and f.h.byName("Option_omit") ~= nil and f.h.byName("Option_value") ~= nil)
	click(f, "Option_omit")
	check("changing temperature preserves search text and identity", f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox") == search and search.Text == "free")
	check("temperature menu writes the selected model override", f.config.get("agent.forceSampling")[f.record.model] == false)
	picker.close(); f.h.settle(0.3); f.healthy(); f.close()
end)

case("provider menus use the same quiet free marker and preserve selection fill", function()
	local f = F.ui(777, 632)
	local theme, overlay = f.env.require("ui/theme"), f.env.require("ui/overlay")
	local menu = overlay.menu({ target = f.host, options = {
		{ label = "Free selected", value = "free-selected", free = true, selected = true },
		{ label = "Free available", value = "free-available", free = true },
		{ label = "Paid available", value = "paid-available" },
	} }); f.h.settle(0.3)
	local selected, available, paid = f.h.byName("Option_free-selected"), f.h.byName("Option_free-available"), f.h.byName("Option_paid-available")
	check("free menu options keep muted rounded outlines", subdued(selected:FindFirstChildOfClass("UIStroke"), theme, theme.color.surfaceOverlay)
		and subdued(available:FindFirstChildOfClass("UIStroke"), theme, theme.color.surfaceOverlay)
		and available:FindFirstChildOfClass("UICorner").CornerRadius.Offset > 0)
	check("the free marker does not imply selection", selected.BackgroundTransparency == 0 and available.BackgroundTransparency == 1)
	check("paid models do not acquire a free outline", not paid:GetAttribute("UAIFreeModel") and paid:FindFirstChildOfClass("UIStroke").Transparency == 1)
	menu.close(); f.h.settle(0.3); f.healthy(); f.close()
end)

case("saved-provider search preserves the model filter and explains desktop routes", function()
	for _, width in ipairs({ 320, 900 }) do
		local f = fixture(width, 632)
		-- Incomplete saved connections must explain setup needs before selection.
		local cline = f.registry.blank("cline"); assert(f.registry.save(cline, { force = true }))
		local keyed = f.registry.blank("custom")
		keyed.label, keyed.baseUrl = "Needs key", "https://provider.fixture/v1?key=private-query"
		assert(f.registry.save(keyed, { force = true }))
		local picker = f.env.require("ui/panels/modelpicker").open(); f.h.settle(0.2)
		local search = f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox")
		search.Text = "fixture"
		click(f, "Section_Endpoint")
		local switcher = f.env.require("ui/panels/providerpicker").open(picker)
		check("provider switcher fits its viewport", switcher.card.Size.X.Offset <= width and switcher.card.Size.Y.Offset <= 632)
		local clineRow, keyedRow = f.h.byName("Option_" .. cline.id), f.h.byName("Option_" .. keyed.id)
		check("unavailable Cline is explicit before selecting", f.h.textOf(clineRow):find("Connect the desktop bridge", 1, true)
			and not f.h.textOf(clineRow):find("uai-tunnel.invalid", 1, true))
		check("key requirements are visible but query credentials are not", f.h.textOf(keyedRow):find("API key required", 1, true)
			and not f.h.textOf(keyedRow):find("private-query", 1, true))
		local providerSearch = f.h.byName("ProviderSwitchSearch"):FindFirstChildOfClass("TextBox")
		f.registry.changed:fire("health", cline); f.h.settle(0.1)
		check("status refresh retains keyboard-focus targets and the search field", f.h.byName(clineRow.Name) == clineRow
			and f.h.byName("ProviderSwitchSearch"):FindFirstChildOfClass("TextBox") == providerSearch)
		providerSearch.Text = "Cline"
		check("saved-provider search filters existing rows", clineRow.Visible and not keyedRow.Visible)
		providerSearch.Text = "no-match"
		check("provider empty state is explicit", f.h.byName("NoSavedProviderMatch").Visible)
		providerSearch.Text = "Cline"; click(f, clineRow.Name)
		check("selection updates the real active record", f.registry.active().id == cline.id and f.h.byName("CurrentProvider").Text == "Cline")
		check("switching providers preserves model search identity", f.h.byName("ModelFilter"):FindFirstChildOfClass("TextBox") == search and search.Text == "fixture")
		click(f, "Section_Endpoint"); picker.close(); f.h.settle(0.3)
		check("owner closure also releases the saved-provider picker", f.h.byName("ProviderSwitchSearch") == nil)
		check("provider browsing performs no requests", f.h.http.requestCount == 0)
		f.healthy(); f.close()
	end
end)

suite.finish()
