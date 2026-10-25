-- Provider context, persistent search, a compact model catalogue, and effort.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local overlay = env.require("ui/overlay")
	local P = env.require("ui/primitives")
	local providers = env.require("provider/registry")
	local models = env.require("provider/models")
	local traits = env.require("provider/traits")
	local freeRoute = env.require("provider/free_route")
	local sampling = env.require("provider/sampling")
	local providerPicker = env.require("ui/panels/providerpicker")
	local M = {}
	local opened

	function M.open(onChange)
		if opened and not opened.closed then return opened end
		local modalProps = { title = "Choose a model", width = theme.size.modelPicker,
			height = providerPicker.preferredHeight(), minTarget = providerPicker.target(), scroll = true }
		local modal = overlay.modal(modalProps)
		if not modal then return end
		opened = modal
		modal.scroll.instance.ScrollingEnabled = false
		modal.content.AutomaticSize = Enum.AutomaticSize.None
		modal.content.Size = UDim2.fromScale(1, 1)
		local root = P.frame(modal.content, { name = "ModelPicker", size = UDim2.fromScale(1, 1) })
		local control = providerPicker.target()
		local filter, freeOnly, fetching = "", false, false
		local visibleCount = 0
		local rows, render, filterRows, renderEffort, fit = {}, nil, nil, nil, nil
		local signature, effortSignature, fitting = nil, nil, false
		local function notify() if not modal.closed and onChange then onChange() end end
		local providerHeight = math.max(control, theme.text.label.height + theme.text.caption.height + theme.space.md * 2 + theme.space.hair)
		local selectionHeight = theme.text.caption.height + theme.space.sm

		local providerButton = P.rowButton(root, { name = "Section_Endpoint", height = providerHeight,
			size = UDim2.new(1, 0, 0, providerHeight), padding = { x = theme.space.md }, gap = theme.space.sm,
			bg = theme.color.surface, stroke = true, strokeColor = theme.color.borderSubtle, radius = theme.radius.md,
			onClick = function() providerPicker.open(modal, notify) end })
		local providerText = P.column(providerButton.row, { size = UDim2.new(0, 0, 0, providerHeight - theme.space.md * 2),
			flex = "Fill", gap = theme.space.hair, layoutOrder = 1 })
		local providerLabel = P.text(providerText, { name = "CurrentProvider", text = "Add a provider", role = "label",
			size = UDim2.new(1, 0, 0, theme.text.label.height), truncate = true, layoutOrder = 1 })
		local providerStatus = P.text(providerText, { name = "CurrentProviderStatus", text = "", role = "caption",
			size = UDim2.new(1, 0, 0, theme.text.caption.height), truncate = true, layoutOrder = 2 })
		P.text(providerButton.row, { text = "Change", role = "caption", color = theme.color.textSecondary, auto = "X", layoutOrder = 2 })
		providerButton.icon("chevron", 3, theme.color.textTertiary)
		local selection = P.row(root, { name = "CurrentSelection", position = UDim2.fromOffset(theme.space.xxs, providerHeight + theme.space.xs),
			size = UDim2.new(1, -theme.space.sm, 0, selectionHeight), gap = theme.space.sm })
		P.text(selection, { text = "Selected", role = "caption", color = theme.color.textTertiary, auto = "X", layoutOrder = 1 })
		local selectionLabel = P.text(selection, { name = "CurrentModel", text = "Choose a model below", role = "caption", color = theme.color.textSecondary,
			size = UDim2.new(0, 0, 0, theme.text.caption.height), flex = "Fill", truncate = true, layoutOrder = 2 })
		local searchTop = providerHeight + selectionHeight + theme.space.md
		local filterWidth = math.max(theme.size.metaColumnWide,
			math.ceil(P.measureText("Free only", { role = "small" }).X) + theme.space.md * 2 + theme.space.sm)
		local searchRow = P.frame(root, { name = "FilterRow", position = UDim2.fromOffset(0, searchTop),
			size = UDim2.new(1, 0, 0, control) })
		local search = P.field(searchRow, { name = "ModelFilter", placeholder = "Search models...", role = "small",
			size = UDim2.new(1, -(filterWidth + theme.space.sm), 0, control),
			onChange = function(text) filter = text; if filterRows then filterRows() end end })
		local freeButton = P.button(searchRow, { name = "FreeOnly", text = "Free only", width = filterWidth,
			position = UDim2.new(1, -filterWidth, 0, 0), size = "md", role = "small", variant = "ghost",
			onClick = function(button)
				freeOnly = not freeOnly
				button.setVariant(freeOnly and "secondary" or "ghost")
				filterRows()
			end })
		providerPicker.sizeButton(freeButton, control)
		local count = P.text(root, { name = "ModelCount", text = "", role = "caption", color = theme.color.textTertiary,
			position = UDim2.fromOffset(theme.space.xxs, searchTop + control + theme.space.sm), size = UDim2.new(1, -theme.space.sm, 0, theme.text.caption.height) })
		local listTop = searchTop + control + theme.space.sm * 2 + theme.text.caption.height
		local rowGap, listPad = theme.space.xs, theme.space.xxs
		local list = P.scroll(root, { name = "ModelScroll", position = UDim2.fromOffset(0, listTop),
			size = UDim2.new(1, 0, 1, -listTop), gap = rowGap,
			padding = { left = theme.space.xxs, right = theme.space.sm, top = theme.space.xxs, bottom = theme.space.xxs },
			bg = theme.color.surface })
		P.corner(list.instance, theme.radius.md)
		local empty = P.text(list.instance, { name = "EmptySearch", text = "No models yet. Use Refresh or add a model ID.",
			role = "small", color = theme.color.textTertiary, wrap = true, auto = "Y", size = UDim2.new(1, 0, 0, 0) })
		local effort = P.column(root, { name = "Section_ReasoningEffort", anchor = Vector2.new(0, 1),
			position = UDim2.fromScale(0, 1), size = UDim2.new(1, 0, 0, control + theme.text.caption.height + theme.space.sm),
			gap = theme.space.xs })
		local function temperatureMenu(target, record)
			local id, policy = record.model, sampling.state(record)
			local automatic = policy.source == "learned" and "This provider rejected temperature; Automatic omits it."
				or "Use known model and provider support"
			overlay.menu({ target = target, options = {
				{ label = "Automatic", value = "auto", selected = policy.override == "auto", detail = automatic },
				{ label = "Send temperature", value = "send", selected = policy.override == "send" },
				{ label = "Omit temperature", value = "omit", selected = policy.override == "omit" },
				{ divider = true }, { label = "Edit shared temperature value", value = "value", detail = tostring(config.get("agent.temperature", 0.4)) },
			}, onSelect = function(value)
				if value == "value" then
					overlay.prompt({ title = "Temperature", description = "Shared value from 0 to 2. Models set to omit do not send it.", value = tostring(config.get("agent.temperature", 0.4)), confirmText = "Save", onConfirm = function(text)
						local number = tonumber(text)
						if not number or number ~= number or number < 0 or number > 2 then overlay.toast("Enter a temperature from 0 to 2", "warn", 3); return end
						config.set("agent.temperature", number); notify()
					end })
				else local ok, why = sampling.set(id, value); if not ok then overlay.toast(tostring(why), "warn", 3) else notify() end end
			end })
		end

		filterRows = function()
			local visible = 0
			local needle = util.trim(filter):lower()
			for _, entry in ipairs(rows) do
				local match = (needle == "" or entry.id:lower():find(needle, 1, true) ~= nil) and (not freeOnly or entry.free)
				entry.button.instance.Visible = match
				if match then visible = visible + 1 end
			end
			count.Text = visible == #rows and util.pluralise(#rows, "model") or string.format("%d of %s", visible, util.pluralise(#rows, "model"))
			visibleCount = visible
			empty.Visible = visible == 0
			empty.Text = #rows == 0 and "No models yet. Use Refresh or add a model ID." or "No matching models. Try another search."
			if fit then fit() end
		end

		renderEffort = function()
			local record = providers.active()
			local levels = record and traits.effortLevels(record.model)
			-- A manual reasoning claim is honored by both request adapters. Offer
			-- the global preferences here too, without inventing documented traits.
			if not levels and record and traits.thinkingStyle(record.model) then levels = { "low", "medium", "high", "xhigh", "max" } end
			local wanted = config.get("agent.effort", "low")
			local sending = wanted == "off" and "off" or (record and traits.nearestEffort(record.model, wanted) or wanted)
			local manual = record and (config.get("agent.forceReasoning", {}) or {})[tostring(record.model):lower()] == true
			local nextEffort = table.concat({ record and record.model or "", table.concat(levels or {}, ","),
				tostring(wanted), tostring(sending), tostring(manual), tostring(control) }, "\0")
			if effortSignature == nextEffort then return end
			effortSignature = nextEffort
			for _, child in ipairs(effort:GetChildren()) do if child:IsA("GuiObject") then child:Destroy() end end
			P.text(effort, { text = levels and (manual and "Reasoning effort (global, manual)" or "Reasoning effort (global)") or "No documented effort control", name = levels and "EffortLabel" or "NoEffort",
				role = "caption", color = theme.color.textTertiary, size = UDim2.new(1, 0, 0, theme.text.caption.height), layoutOrder = 1 })
			if levels then
				local strip = P.scroll(effort, { name = "EffortPills", horizontal = true, gap = theme.space.xs,
					size = UDim2.new(1, 0, 0, control), layoutOrder = 2, bar = 0 })
				local choices = util.copy(levels)
				choices[#choices + 1] = "off"
				for index, level in ipairs(choices) do
					providerPicker.sizeButton(P.button(strip.instance, { name = "Effort_" .. level, text = level == "off" and "Provider default" or level:gsub("^%l", string.upper),
						variant = level == sending and "secondary" or "ghost", size = "sm", layoutOrder = index,
						onClick = function() config.set("agent.effort", level); notify() end }), control)
				end
			end
			local height = levels and (control + theme.text.caption.height + theme.space.sm) or 0
			effort.Visible = levels ~= nil
			effort.Size = UDim2.new(1, 0, 0, height)
			if fit then fit() end
		end
		fit = function()
			if modal.closed or fitting then return end
			fitting = true
			local height = effort.Size.Y.Offset
			local room = math.max(0, modal.scroll.viewportSize().Y)
			local footerSpace = height > 0 and height + theme.space.md or 0
			local function rowsHeight(count) return count * control + math.max(0, count - 1) * rowGap + listPad * 2 end
			local natural = rowsHeight(math.max(1, visibleCount))
			local compact = room < listTop + footerSpace + rowsHeight(math.min(5, math.max(1, visibleCount)))
			-- One scrolling owner: short/keyboard layouts scroll the whole body;
			-- ordinary layouts pin the search and scroll only the catalogue.
			local available = room - listTop - footerSpace
			local fittingRows = math.max(1, math.floor((available - listPad * 2 + rowGap) / (control + rowGap)))
			local listHeight = compact and natural or rowsHeight(fittingRows)
			local contentHeight = compact and listTop + natural + footerSpace or room
			modal.content.Size = UDim2.new(1, 0, 0, contentHeight)
			modal.scroll.instance.ScrollingEnabled = compact
			list.instance.ScrollingEnabled = not compact
			list.instance.Size = UDim2.new(1, 0, 0, listHeight)
			if compact then list.instance.CanvasPosition = Vector2.new(0, 0) end
			fitting = false
		end
		modal.scroll.instance:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() if fit then fit() end end)

		render = function()
			if modal.closed then return end
			local record = providers.active()
			providerLabel.Text = record and record.label or "Add a provider"
			local providerInfo = providerPicker.describe(record)
			providerStatus.Text, providerStatus.TextColor3 = providerInfo.detail, providerInfo.tone
			selectionLabel.Text = record and util.trim(record.model) ~= "" and record.model or "Choose a model below"
			local known = record and models.list(record) or {}
			local labels = {}
			for _, id in ipairs(known) do labels[#labels + 1] = id .. tostring(models.isFree(record, id)) end
			local nextSignature = (record and record.id or "") .. "\0" .. table.concat(labels, "\0")
			if signature ~= nextSignature then
				for _, entry in ipairs(rows) do entry.button.instance:Destroy() end
				rows = {}
				list.instance.CanvasPosition = Vector2.new(0, 0)
				for index, id in ipairs(known) do
					local selected = id == record.model
					local free = models.isFree(record, id)
					local button = P.rowButton(list.instance, { name = "Model_" .. id, height = control,
						selected = selected, bgSelected = theme.color.surfaceActive, radius = theme.radius.sm,
						stroke = free, strokeColor = free and P.freeModelOutline(theme.color.surface) or nil,
						strokeWidth = free and 1 or nil,
						padding = { x = theme.space.sm }, gap = theme.space.sm, layoutOrder = index,
						onClick = function() providers.setModel(record.id, id); notify() end })
					local label = button.label(id, 1, selected and theme.color.text or theme.color.textSecondary, "small")
					local badge = traits.badge(id, record)
					local meta = P.text(button.row, { text = badge or "", role = "caption", color = theme.color.textTertiary,
						size = UDim2.fromOffset(theme.size.metaColumnWide, theme.text.caption.height), align = "Right", truncate = true, layoutOrder = 2 })
					local mark = button.icon("check", 3, theme.color.accentHot)
					mark.Visible = selected
					rows[#rows + 1] = { id = id, free = free, button = button, label = label, mark = mark, meta = meta }
				end
				signature = nextSignature
			end
			for _, entry in ipairs(rows) do
				local selected = record and entry.id == record.model
				entry.button.setSelected(selected)
				entry.label.TextColor3 = selected and theme.color.text or theme.color.textSecondary
				entry.mark.Visible = selected == true
				local badge = traits.badge(entry.id, record)
				entry.label.Text = entry.id
				entry.meta.Text = entry.free and ("Free" .. (badge and " | " .. badge or "")) or (badge or "")
				entry.meta.TextColor3 = entry.free and theme.color.success or theme.color.textTertiary
				entry.meta.Visible = entry.meta.Text ~= ""
				if entry.id == "auto" then
					local route = freeRoute.status(record)
					if route.supported and route.enabled == false then
						entry.label.Text, entry.meta.Text = "Auto (provider routing)", "Free | Automatic routing off"
					elseif freeRoute.eligible(record) then
						entry.label.Text = "Auto (fastest verified)"
						entry.meta.Text = route.ms and string.format("Free | %.1fs probe", route.ms / 1000)
							or (route.running and "Free | Measuring" or "Free")
					end
				end
				entry.meta.Size = UDim2.fromOffset(math.min(math.max(theme.size.metaColumnWide, theme.text.caption.size * 8),
					math.ceil(P.measureText(entry.meta.Text, { role = "caption" }).X) + theme.space.sm), theme.text.caption.height)
			end
			filterRows()
			renderEffort()
			local chrome = modal.card.Size.Y.Offset - modal.scroll.instance.Size.Y.Offset
			modalProps.height = math.min(providerPicker.preferredHeight(), chrome + listTop
				+ math.min(math.max(#rows, 2), 7) * (control + rowGap) + theme.space.lg
				+ effort.Size.Y.Offset + theme.space.md)
			modal.relayout()
			fit()
		end

		P.button(modal.footer, { name = "FetchModels", text = "Refresh", variant = "ghost", size = "sm", layoutOrder = 1,
			onClick = function(button)
				local record = providers.active()
				if not record or fetching then return end
				fetching = true; button.setEnabled(false); button.setText("Fetching…")
				local superseded = false
				local function aborted() return superseded or modal.closed or providers.active() ~= record end
				local unsubscribe = providers.changed:connect(function()
					if providers.active() ~= record then superseded = true end
				end)
				local closed = modal.scrim.Destroying:Connect(function() superseded = true; unsubscribe() end)
				task.spawn(function()
					local ok, found, note = pcall(models.discover, record, { force = true, aborted = aborted })
					unsubscribe(); closed:Disconnect()
					fetching = false
					if modal.closed then return end
					button.setEnabled(true); button.setText("Refresh")
					if aborted() then return end
					overlay.toast(tostring(ok and note or found), ok and #found > 0 and "good" or "warn", 3)
					render(); notify()
				end)
			end })
		P.button(modal.footer, { name = "ModelOptions", text = "Options", variant = "ghost", size = "sm", layoutOrder = 2,
			onClick = function(button)
				local record = providers.active()
				local id = record and tostring(record.model):lower() or ""
				local forced = (config.get("agent.forceReasoning", {}) or {})[id] == true
				local policy = record and sampling.state(record)
				local mode = policy and (({ auto = "Automatic", send = "Send", omit = "Omit" })[policy.override] or "Automatic")
				local options = {
					{ label = "Temperature", value = "temperature", detail = policy and (mode .. (policy.allowed and (" · " .. tostring(config.get("agent.temperature", 0.4))) or " · omitted")) or "Choose a provider first" },
					{ label = "Add model ID", value = "add", icon = "plus" },
					{ label = "Reasoning support", value = "reasoning", selected = forced, detail = "Override for the selected model" },
					{ label = "Context window", value = "context", detail = "Override for the selected model" },
					{ label = "Manage providers", value = "manage", icon = "sliders" },
				}
				overlay.menu({ target = button.instance, options = options, onSelect = function(value)
					if value == "manage" then modal.close(); env.require("ui/app").show("providers"); return end
					if not record then overlay.toast("Add a provider first", "info", 2); return end
					if value == "temperature" then temperatureMenu(button.instance, record)
					elseif value == "add" then
						overlay.prompt({ title = "Add a model ID", placeholder = "Exact model ID", confirmText = "Add", onConfirm = function(text)
							local ok, note = models.add(record, text)
							if ok then providers.setModel(record.id, util.trim(text)) end
							overlay.toast(tostring(note), ok and "good" or "warn", 3); notify()
						end })
					elseif id ~= "" and value == "reasoning" then
						local claims = config.get("agent.forceReasoning", {}) or {}
						claims[id] = not forced; config.set("agent.forceReasoning", claims); notify()
					elseif id ~= "" and value == "context" then
						local claims = config.get("agent.forceContext", {}) or {}
						overlay.prompt({ title = "Context window", description = "Token limit. Leave empty to use the documented value.",
							placeholder = "1000000", value = claims[id] and tostring(claims[id]) or "", confirmText = "Save",
							onConfirm = function(text)
								local number = tonumber(text)
								if util.trim(text) ~= "" and (not number or number <= 0 or number == math.huge) then
									overlay.toast("Enter a positive token count", "warn", 2); return
								end
								claims[id] = number and math.floor(number) or nil
								config.set("agent.forceContext", claims); notify()
							end })
					end
				end })
			end })
		P.button(modal.footer, { name = "PickerDone", text = "Done", variant = "primary", size = "sm", layoutOrder = 3,
			onClick = function() modal.close() end })
		local function sizeFooter()
			for _, button in ipairs(modal.footer:GetChildren()) do
				if button:IsA("GuiButton") then providerPicker.sizeButton({ instance = button }, control) end
			end
		end
		sizeFooter()
		local unsubscribe = providers.changed:connect(function(kind)
			if kind == "health" then
				local info = providerPicker.describe(providers.active())
				providerStatus.Text, providerStatus.TextColor3 = info.detail, info.tone
			end
			if kind ~= "health" then
				render()
				local record = providers.active()
				if record then freeRoute.refresh(record) end
			end
		end)
		local unsubscribeRoute = freeRoute.changed:connect(render)
		local unsubscribeModels = models.changed:connect(render)
		local unsubscribeBridge = env.require("net/bridge").changed:connect(render)
		local unsubscribeConfig = config.changed:connect(function(path)
			if path == nil or path == "agent" or path == "agent.effort" or path == "agent.forceReasoning"
				or path == "agent.forceContext" or path == "agent.forceSampling" or path == "agent.temperature" or path == "agent.autoFreeRouting" then render() end
		end)
		local unsubscribeResponsive = responsive.changed:connect(function()
			if modal.closed then return end
			local target = providerPicker.target()
			if target == control then fit(); return end
			control = target
			modalProps.minTarget = target
			sizeFooter()
			searchRow.Position = UDim2.fromOffset(0, searchTop)
			searchRow.Size = UDim2.new(1, 0, 0, control)
			search.shell.Size = UDim2.new(1, -(filterWidth + theme.space.sm), 0, control)
			freeButton.instance.Size = UDim2.fromOffset(math.max(filterWidth, target), control)
			count.Position = UDim2.fromOffset(theme.space.xxs, searchTop + control + theme.space.sm)
			listTop = searchTop + control + theme.space.sm * 2 + theme.text.caption.height
			list.instance.Position = UDim2.fromOffset(0, listTop)
			for _, entry in ipairs(rows) do entry.button.instance.Size = UDim2.new(1, 0, 0, control) end
			render()
		end)
		modal.scrim.Destroying:Connect(function() unsubscribe(); unsubscribeRoute(); unsubscribeModels(); unsubscribeBridge(); unsubscribeConfig(); unsubscribeResponsive() end)
		render()
		local record = providers.active()
		if record then freeRoute.refresh(record) end
		modal.render = render
		return modal
	end
	return M
end
