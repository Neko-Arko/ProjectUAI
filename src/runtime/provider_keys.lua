-- Ordered provider credentials and their user-owned labels/request policy.
-- This data-only module is shared by configuration transfer and presentation.
return function(env)
	local util = env.require("runtime/util")
	local M = {}

	function M.keys(record)
		local keys, seen = {}, {}
		for token in tostring(record and record.apiKey or ""):gmatch("[^\r\n,]+") do
			local key = util.trim(token)
			if key ~= "" and not seen[key] then
				seen[key] = true
				keys[#keys + 1] = key
			end
		end
		return keys
	end

	function M.mode(record)
		return record and record.keyMode == "single" and "single" or "rotate"
	end

	local function validIndex(value, count)
		return type(value) == "number" and value >= 1 and value <= count and value % 1 == 0
	end

	function M.selected(record)
		local value = record and record.selectedKey
		if value == nil then return 1 end
		return value
	end

	local function nameProblem(name)
		if type(name) ~= "string" then return "API key names must be text." end
		if not util.validUtf8(name) then return "API key names must contain valid UTF-8 text." end
		if name:find("[%z\1-\31\127]") or name:find("\194[\128-\159]")
			or name:find("\226\128\168", 1, true) or name:find("\226\128\169", 1, true) then
			return "API key names must use one line without control characters."
		end
		if #util.trim(name) > 120 then return "API key names must be at most 120 UTF-8 bytes." end
	end

	function M.entries(record)
		local entries, names = {}, type(record and record.keyNames) == "table" and record.keyNames or {}
		for index, key in ipairs(M.keys(record)) do
			entries[index] = { key = key, name = type(names[index]) == "string" and util.trim(names[index]) or "" }
		end
		return entries
	end

	function M.requestKeys(record)
		local keys = M.keys(record)
		if M.mode(record) == "single" then
			local selected = M.selected(record)
			local key = validIndex(selected, #keys) and keys[selected] or nil
			return key and { key } or {}
		end
		return keys
	end

	function M.validate(record)
		if type(record) ~= "table" then return false, "provider must be an object" end
		local count = #M.keys(record)
		if record.keyMode ~= nil and record.keyMode ~= "rotate" and record.keyMode ~= "single" then
			return false, "keyMode must be rotate or single"
		end
		if record.selectedKey ~= nil and not validIndex(record.selectedKey, math.max(1, count)) then
			return false, "selectedKey must identify an existing API key"
		end
		if record.keyMode == "single" and count == 0 then return false, "single key mode requires an API key" end
		if record.keyNames ~= nil then
			if type(record.keyNames) ~= "table" then return false, "keyNames must be an array of strings" end
			local found = 0
			for index, name in pairs(record.keyNames) do
				if not validIndex(index, count) or type(name) ~= "string" then
					return false, "keyNames must contain one string for each API key"
				end
				local problem = nameProblem(name)
				if problem then return false, "keyNames: " .. problem end
				if name ~= util.trim(name) then return false, "keyNames must not start or end with whitespace" end
				found = found + 1
			end
			if found ~= count then return false, "keyNames must contain one string for each API key" end
		end
		return true
	end

	local function namesOf(record, count)
		local names, saved = {}, type(record.keyNames) == "table" and record.keyNames or {}
		for index = 1, count do names[index] = type(saved[index]) == "string" and util.trim(saved[index]) or "" end
		return names
	end

	local function write(record, keys, names, mode, selected)
		local changedKeys = table.concat(M.keys(record), "\n") ~= table.concat(keys, "\n")
		if changedKeys or M.mode(record) ~= mode or M.selected(record) ~= selected then record.keyRotation = nil end
		-- Renaming an entry must not invalidate an in-flight request or model cache.
		if changedKeys then record.apiKey = table.concat(keys, "\n") end
		record.keyNames, record.keyMode, record.selectedKey = names, mode, selected
		return true
	end

	function M.add(record, text)
		local ok, err = M.validate(record)
		if not ok then return false, err end
		local incoming, keys = M.keys({ apiKey = text }), M.keys(record)
		if #incoming == 0 then return false, "Enter at least one API key." end
		local names, seen, added = namesOf(record, #keys), {}, 0
		for _, key in ipairs(keys) do seen[key] = true end
		for _, key in ipairs(incoming) do
			if not seen[key] then
				keys[#keys + 1], names[#names + 1], seen[key], added = key, "", true, added + 1
			end
		end
		write(record, keys, names, M.mode(record), M.selected(record))
		return true, added
	end

	function M.replace(record, index, text)
		local ok, err = M.validate(record)
		if not ok then return false, err end
		local keys, incoming = M.keys(record), M.keys({ apiKey = text })
		if not validIndex(index, #keys) then return false, "That API key no longer exists." end
		if #incoming ~= 1 then return false, "Enter one replacement API key." end
		for position, key in ipairs(keys) do
			if position ~= index and key == incoming[1] then return false, "That API key is already in another entry." end
		end
		keys[index] = incoming[1]
		return write(record, keys, namesOf(record, #keys), M.mode(record), M.selected(record))
	end

	function M.remove(record, index)
		local ok, err = M.validate(record)
		if not ok then return false, err end
		local keys = M.keys(record)
		if not validIndex(index, #keys) then return false, "That API key no longer exists." end
		local names, selected, mode = namesOf(record, #keys), M.selected(record), M.mode(record)
		table.remove(keys, index)
		table.remove(names, index)
		if selected == index then
			selected = 1
			if mode == "single" then mode = "rotate" end
		elseif selected > index then selected = selected - 1 end
		return write(record, keys, names, mode, selected)
	end

	function M.rename(record, index, name)
		local ok, err = M.validate(record)
		if not ok then return false, err end
		local keys = M.keys(record)
		if not validIndex(index, #keys) then return false, "That API key no longer exists." end
		local problem = nameProblem(name)
		if problem then return false, problem end
		local names = namesOf(record, #keys)
		names[index] = util.trim(name)
		return write(record, keys, names, M.mode(record), M.selected(record))
	end

	function M.setMode(record, mode, selected)
		local keys = M.keys(record)
		if mode ~= "rotate" and mode ~= "single" then return false, "Choose Rotate keys or Use one key." end
		if selected == nil then
			selected = M.selected(record)
			if mode == "rotate" and not validIndex(selected, math.max(1, #keys)) then selected = 1 end
		end
		if not validIndex(selected, math.max(1, #keys)) then return false, "Choose an existing API key." end
		if mode == "single" and #keys == 0 then return false, "Add an API key before choosing Use one key." end
		return write(record, keys, namesOf(record, #keys), mode, selected)
	end

	return M
end
