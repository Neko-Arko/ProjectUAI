return function(env)
	local C = env.require("core")
	local T = env.require("theme")
	local M = {}
	local function encodeColor(color) return { color.R, color.G, color.B } end
	local function decodeColor(rgb, label)
		assert(type(rgb) == "table" and #rgb == 3, "Invalid appearance " .. label)
		for key in pairs(rgb) do assert(key == 1 or key == 2 or key == 3, "Invalid appearance " .. label) end
		for index = 1, 3 do
			assert(C.finite(rgb[index]) and rgb[index] >= 0 and rgb[index] <= 1, "Invalid appearance " .. label)
		end
		return Color3.new(rgb[1], rgb[2], rgb[3])
	end
	local function decodeAppearance(value, current)
		assert(type(value) == "table" and (value.theme == "Dark" or value.theme == "Light"), "Invalid appearance theme")
		local patch = { Theme = value.theme, Accent = false }
		if value.accent ~= nil then patch.Accent = decodeColor(value.accent, "accent") end
		if value.colors ~= nil then
			assert(type(value.colors) == "table", "Invalid appearance colors")
			patch.Colors = {}
			for token, rgb in pairs(value.colors) do
				assert(type(token) == "string", "Invalid appearance color name")
				patch.Colors[token] = decodeColor(rgb, "color " .. token)
			end
		end
		patch.CornerRadius, patch.TextScale, patch.ReducedMotion = value.cornerRadius, value.textScale, value.reducedMotion
		-- Keep omission meaningful for older profiles, including following Roblox's
		-- motion preference when no saved override was present.
		T.normalizeAppearance(patch, current)
		return patch
	end
	function M.ExportConfig(self)
		assert(self.Alive, "Window is destroyed")
		local values = {}
		for id, control in pairs(self.Controls) do
			if control._normalize and control.Persist ~= false then
				local value
				if control._encode then value = control._encode() else value = control:Get() end
				values[id] = { kind = control.Kind, value = value }
			end
		end
		local current = self:GetAppearance()
		local appearance = {
			theme = current.Theme, colors = {}, cornerRadius = current.CornerRadius,
			textScale = current.TextScale, reducedMotion = current.ReducedMotion,
		}
		if current.Accent then appearance.accent = encodeColor(current.Accent) end
		for token, color in pairs(current.Colors) do appearance.colors[token] = encodeColor(color) end
		return env.services.HttpService:JSONEncode({ format = "project-uai-ui", version = 1, window = self.Id, values = values, appearance = appearance })
	end
	function M.ImportConfig(self, source, options)
		options = options or {}
		if not self.Alive then return false, "Window is destroyed" end
		if type(source) ~= "string" or #source > 262144 then return false, "Configuration must be JSON under 256 KiB" end
		local ok, document = pcall(function() return env.services.HttpService:JSONDecode(source) end)
		if not ok or type(document) ~= "table" or document.format ~= "project-uai-ui" or document.version ~= 1 or type(document.values) ~= "table" then
			return false, "Unsupported or invalid UI configuration"
		end
		if document.window ~= self.Id then return false, "Configuration belongs to a different window Id" end
		local appearance
		if document.appearance ~= nil then
			local valid, patch = pcall(decodeAppearance, document.appearance, self:GetAppearance())
			if not valid then return false, tostring(patch) end
			appearance = patch
		end
		local pending = {}
		for id, record in pairs(document.values) do
			local control = self.Controls[id]
			if control and control._normalize and control.Persist ~= false then
				if type(record) ~= "table" or record.kind ~= control.Kind then return false, "Control type changed: " .. tostring(id) end
				local valid, normalized = pcall(control._decode or control._normalize, record.value)
				if not valid then return false, "Invalid value for " .. tostring(id) .. ": " .. tostring(normalized) end
				pending[#pending + 1] = { control = control, value = normalized, changed = not C.equal(control._value, normalized) }
			end
		end
		table.sort(pending, function(a, b) return a.control.Id < b.control.Id end)
		-- All values validate before the first write. Callbacks see the complete
		-- restored configuration and are opt-in, so loading cannot start actions.
		if appearance then self:SetAppearance(appearance) end
		local releases = {}
		for _, item in ipairs(pending) do
			if item.control._restore then
				local release = item.control._restore(item.value)
				if release then releases[#releases + 1] = release end
			else item.control:Set(item.value, true) end
		end
		-- End active key actions only after every value is restored. Cleanup
		-- callbacks may destroy controls without interrupting the transaction.
		for _, release in ipairs(releases) do release() end
		if options.Silent == false then
			for _, item in ipairs(pending) do if item.changed and item.control.Alive then item.control:_Emit() end end
		end
		return true, #pending
	end
	local function pathFor(self, name)
		assert(type(name) == "string" and #name > 0 and #name <= 48 and name:match("^[%w_-]+$"), "Profile name must be 1-48 letters, digits, underscores, or hyphens")
		local hash = 5381
		for index = 1, #self.Id do hash = (hash * 33 + self.Id:byte(index)) % 4294967296 end
		local folder = "ProjectUAI/UI/" .. self.Id:gsub("[^%w_-]", "_"):sub(1, 32) .. "-" .. string.format("%08x", hash)
		return folder .. "/" .. name .. ".json", folder
	end
	function M.SaveConfig(self, name)
		local write = env.globals.writefile or writefile
		local make = env.globals.makefolder or makefolder
		local exists = env.globals.isfolder or isfolder
		local read = env.globals.readfile or readfile
		if type(write) ~= "function" or type(make) ~= "function" then return false, "This host does not provide writefile and makefolder; use ExportConfig" end
		local ok, result = pcall(function()
			local path, folder = pathFor(self, name)
			for _, directory in ipairs({ "ProjectUAI", "ProjectUAI/UI", folder }) do
				if type(exists) ~= "function" or not exists(directory) then
					local made, why = pcall(make, directory)
					if not made and type(exists) == "function" and not exists(directory) then error(why, 0) end
				end
			end
			local json = self:ExportConfig()
			write(path, json)
			if type(read) == "function" then assert(read(path) == json, "Configuration read-back did not match") end
			return path
		end)
		return ok, result
	end
	function M.LoadConfig(self, name, options)
		local read = env.globals.readfile or readfile
		if type(read) ~= "function" then return false, "This host does not provide readfile; use ImportConfig" end
		local ok, result = pcall(function()
			local path = pathFor(self, name)
			return read(path)
		end)
		if not ok then return false, tostring(result) end
		return self:ImportConfig(result, options)
	end
	return M
end
