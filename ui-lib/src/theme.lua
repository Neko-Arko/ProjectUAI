-- Graphite chrome, inset surfaces and a warm signal color. Window surfaces use
-- opaque native UI; consumer scripts continue to own only content and behavior.
return function(env)
	local rgb = Color3.fromRGB
	local M = {}
	M.Dark = {
		Canvas = rgb(23, 25, 29), Sidebar = rgb(17, 19, 22), Chrome = rgb(20, 22, 26),
		Surface = rgb(30, 33, 38), Raised = rgb(39, 43, 49), Input = rgb(22, 25, 29),
		Hover = rgb(48, 52, 59), Pressed = rgb(59, 64, 72), Track = rgb(47, 52, 61),
		Border = rgb(79, 85, 95), Subtle = rgb(46, 51, 59), Edge = rgb(61, 67, 77),
		Text = rgb(242, 243, 245), Secondary = rgb(193, 198, 207),
		Muted = rgb(153, 161, 174), Disabled = rgb(106, 113, 124),
		Accent = rgb(235, 148, 117), OnAccent = rgb(22, 24, 28),
		Primary = rgb(244, 240, 232), OnPrimary = rgb(22, 24, 28),
		Success = rgb(125, 211, 167), Warning = rgb(237, 193, 119),
		Danger = rgb(247, 145, 151), Scrim = rgb(7, 9, 12),
	}
	M.Light = {
		Canvas = rgb(246, 247, 249), Sidebar = rgb(236, 238, 242), Chrome = rgb(241, 243, 246),
		Surface = rgb(255, 255, 255), Raised = rgb(233, 236, 241), Input = rgb(246, 247, 249),
		Hover = rgb(226, 230, 237), Pressed = rgb(212, 218, 228), Track = rgb(221, 226, 234),
		Border = rgb(157, 166, 181), Subtle = rgb(221, 226, 234), Edge = rgb(203, 210, 221),
		Text = rgb(28, 33, 42), Secondary = rgb(65, 75, 91),
		Muted = rgb(98, 108, 125), Disabled = rgb(139, 148, 163),
		Accent = rgb(167, 69, 44), OnAccent = rgb(255, 255, 255),
		Primary = rgb(31, 37, 47), OnPrimary = rgb(255, 255, 255),
		Success = rgb(26, 117, 76), Warning = rgb(136, 87, 21),
		Danger = rgb(179, 49, 65), Scrim = rgb(7, 9, 12),
	}
	M.Size = {
		Target = 40, TouchTarget = 44, TouchSlop = 8, Gap = 12, Pad = 20, MobilePad = 12,
		Header = 80, Footer = 30, Sidebar = 196, Tabs = 52, Avatar = 36,
		Radius = 10, FieldRadius = 6, Scrollbar = 3,
		Width = 780, Height = 580, Compact = 640,
	}
	M.Type = { Display = 26, Title = 20, Heading = 15, Body = 14, Caption = 12, Small = 11, Eyebrow = 10 }
	M.Motion = { Fast = 0.10, Enter = 0.16, Toggle = 0.14, Press = 0.06 }
	local function linear(channel)
		if channel <= 0.04045 then return channel / 12.92 end
		return ((channel + 0.055) / 1.055) ^ 2.4
	end
	local function color(value, label)
		assert(typeof(value) == "Color3", label .. " must be a Color3")
		for _, channel in ipairs({ value.R, value.G, value.B }) do
			assert(channel == channel and channel >= 0 and channel <= 1, label .. " components must be between 0 and 1")
		end
		return value
	end
	local function foreground(value)
		local luminance = linear(value.R) * 0.2126 + linear(value.G) * 0.7152 + linear(value.B) * 0.0722
		return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) and rgb(0, 0, 0) or rgb(255, 255, 255)
	end
	function M.normalizeAppearance(options, current)
		assert(type(options) == "table", "Appearance must be a table")
		current = current or { Theme = "Dark", Colors = {}, CornerRadius = M.Size.Radius, TextScale = 1, ReducedMotion = false }
		local result = {}
		for key, value in pairs(current) do result[key] = value end
		for key, value in pairs(options) do
			assert(key == "Theme" or key == "Accent" or key == "Colors" or key == "CornerRadius" or key == "TextScale" or key == "ReducedMotion", "Unknown appearance option: " .. tostring(key))
			if key == "Theme" then
				assert(value == "Dark" or value == "Light", "Theme must be Dark or Light")
			elseif key == "Accent" then
				if value ~= false then color(value, "Accent") end
			elseif key == "Colors" then
				assert(type(value) == "table", "Colors must be a table")
			elseif key == "ReducedMotion" then
				assert(type(value) == "boolean", "ReducedMotion must be a boolean")
			else
				local low, high = key == "CornerRadius" and 0 or 0.85, key == "CornerRadius" and 16 or 1.5
				assert(type(value) == "number" and value == value and value >= low and value <= high, key .. " is outside its supported range")
			end
			result[key] = value
		end
		if result.Accent == false then result.Accent = nil end
		local colors = {}
		for key, value in pairs(result.Colors or {}) do
			assert(M.Dark[key] ~= nil or key == "Selected" or key == "AccentSoft", "Unknown color token: " .. tostring(key))
			assert(key ~= "Accent", "Use Accent to customize the accent color")
			colors[key] = color(value, "Colors." .. key)
		end
		result.Colors = colors
		return result
	end
	function M.resolve(name, accent, colors)
		assert(name == nil or name == "Dark" or name == "Light", "Theme must be Dark or Light")
		local result = {}
		for key, value in pairs(M[name or "Dark"]) do result[key] = value end
		if accent ~= nil then
			result.Accent = color(accent, "Accent")
		end
		for key, value in pairs(colors or {}) do result[key] = value end
		if accent or (colors and colors.Accent) then result.OnAccent = colors and colors.OnAccent or foreground(result.Accent) end
		if colors and colors.Primary and not colors.OnPrimary then result.OnPrimary = foreground(result.Primary) end
		result.Selected = result.Raised:Lerp(result.Accent, 0.16)
		result.AccentSoft = result.Surface:Lerp(result.Accent, 0.12)
		if colors and colors.Selected then result.Selected = colors.Selected end
		if colors and colors.AccentSoft then result.AccentSoft = colors.AccentSoft end
		return result
	end
	return M
end
