-- Built-in personalization uses the same owned, declarative controls as scripts.
-- Its values reflect the window appearance; configuration stores that one source.
return function(env)
	local C = env.require("core")
	local M = {}
	local prefix = "__uai_appearance_"
	function M.mount(window)
		local tab = window:Tab({ Id = prefix .. "tab", Title = "Appearance" })
		window._appearanceTab = tab
		local controls, colors = {}, {}
		local appearance = window:GetAppearance()
		local function options(id, text, default, callback)
			return { Id = prefix .. id, Text = text, Default = default, Callback = callback, Persist = false }
		end
		local personalize = tab:Section({
			Title = "Make it yours", Description = "Changes apply immediately to this window and are included in saved profiles.",
		})
		local mode = options("theme", "Color mode", appearance.Theme, function(value) window:SetAppearance({ Theme = value }) end)
		mode.Options = { "Dark", "Light" }
		controls.Theme = personalize:Segmented(mode)
		controls.Accent = personalize:ColorPicker(options("accent", "Accent color", window.Theme.Accent, function(value)
			local overrides = window:GetAppearance().Colors
			overrides.Accent = nil
			window:SetAppearance({ Accent = value, Colors = overrides })
		end))
		personalize:Button({
			Id = prefix .. "reset_colors", Text = "Default palette", ActionText = "Reset colors", Persist = false,
			Description = "Restore the colors for your current mode.",
			Callback = function() window:SetAppearance({ Accent = false, Colors = {} }) end,
		})
		local comfort = tab:Section({ Title = "Shape and comfort" })
		local radius = options("corner_radius", "Corner radius", appearance.CornerRadius, function(value) window:SetAppearance({ CornerRadius = value }) end)
		radius.Min, radius.Max, radius.Step, radius.Suffix = 0, 16, 1, " px"
		controls.CornerRadius = comfort:Slider(radius)
		local scale = options("text_scale", "Text size", appearance.TextScale * 100, function(value) window:SetAppearance({ TextScale = value / 100 }) end)
		scale.Min, scale.Max, scale.Step, scale.Suffix = 85, 150, 1, "%"
		controls.TextScale = comfort:Slider(scale)
		local reduced = options("reduced_motion", "Reduced motion", appearance.ReducedMotion, function(value) window:SetAppearance({ ReducedMotion = value }) end)
		reduced.Description = "Keep transitions still and immediate."
		controls.ReducedMotion = comfort:Toggle(reduced)
		local function paletteSection(title, entries)
			local section = tab:Section({ Title = title, Collapsible = true, Collapsed = true })
			for _, entry in ipairs(entries) do
				local token, label = entry[1], entry[2]
				colors[token] = section:ColorPicker(options("color_" .. token, label, window.Theme[token], function(value)
					local overrides = window:GetAppearance().Colors
					overrides[token] = value
					window:SetAppearance({ Colors = overrides })
				end))
			end
		end
		paletteSection("Surfaces", {
			{ "Canvas", "Workspace" }, { "Sidebar", "Navigation" }, { "Chrome", "Window header" },
			{ "Surface", "Sections and panels" }, { "Raised", "Raised surfaces" }, { "Input", "Input fields" },
		})
		paletteSection("Text colors", {
			{ "Text", "Main text" }, { "Secondary", "Supporting text" }, { "Muted", "Muted text" }, { "Disabled", "Disabled text" },
		})
		paletteSection("Actions and status", {
			{ "OnAccent", "Text on accent" }, { "Primary", "Primary actions" }, { "OnPrimary", "Text on primary" },
			{ "Success", "Success" }, { "Warning", "Warning" }, { "Danger", "Danger" },
		})
		paletteSection("Interaction colors", {
			{ "Hover", "Hover" }, { "Pressed", "Pressed" }, { "Track", "Slider tracks" },
			{ "Selected", "Selected navigation" }, { "AccentSoft", "Soft accent" },
		})
		paletteSection("Borders and overlays", {
			{ "Border", "Focus borders" }, { "Subtle", "Subtle dividers" }, { "Edge", "Surface edges" }, { "Scrim", "Overlay backdrop" },
		})
		local reset = tab:Section({ Title = "Restore appearance" })
		reset:Button({
			Id = prefix .. "reset", Text = "Original appearance", ActionText = "Reset all", Persist = false,
			Description = "Restore this window's starting palette, corners, text size, and motion preference.",
			Callback = function() window:ResetAppearance() end,
		})
		local function reflect(control, value)
			if control.Alive and not C.equal(control:Get(), value) then control:Set(value, true) end
		end
		window._appearanceSync = function()
			if not window.Alive or not tab.Alive then return end
			local current = window:GetAppearance()
			reflect(controls.Theme, current.Theme)
			reflect(controls.Accent, window.Theme.Accent)
			reflect(controls.CornerRadius, current.CornerRadius)
			reflect(controls.TextScale, current.TextScale * 100)
			reflect(controls.ReducedMotion, current.ReducedMotion)
			for token, control in pairs(colors) do reflect(control, window.Theme[token]) end
		end
		window:OnDestroy(function() window._appearanceSync, window._appearanceTab = nil, nil end)
		return tab
	end
	return M
end
