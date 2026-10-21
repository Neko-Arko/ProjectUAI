-- Durable tool evidence, kept outside the conversation context.
--
-- Every tool result is copied under the app root with a small per-session
-- index. The model still receives its normal inline receipt; this ledger is for
-- recovering full text or structured data later, especially after compaction.
return function(env)
	local fs = env.require("runtime/fsx")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")

	local M = { enabled = fs.enabled ~= false, root = "evidence" }
	M.limits = { records = 200, text = 512 * 1024, data = 1024 * 1024, total = 16 * 1024 * 1024 }
	local serial = 0

	local function clean(value)
		local text = tostring(value or "")
		if #text == 0 or #text > 96 or not text:match("^[%w_-]+$") then return nil end
		return text
	end

	local function directory(session)
		local id = clean(session)
		if not id then return nil end
		return M.root .. "/" .. id
	end

	local function indexPath(session)
		local dir = directory(session)
		return dir and (dir .. "/index.json") or nil
	end

	local function recordPath(session, id)
		local dir = directory(session)
		return dir and (dir .. "/" .. id .. ".json") or nil
	end

	local function readIndex(session)
		local path = indexPath(session)
		if not path then return {} end
		local value = fs.readJson(path, {})
		return type(value) == "table" and value or {}
	end

	local function writeIndex(session, index)
		local path = indexPath(session)
		if not path then return false end
		return fs.writeJson(path, index)
	end

	local function clip(value, limit)
		value = type(value) == "string" and value or ""
		if #value <= limit then return value, false end
		return value:sub(1, limit), true
	end

	function M.record(session, tool, text, data, info)
		if not M.enabled or type(session) ~= "table" then return nil end
		local id = clean(session.id)
		if not id then return nil end
		tool = tostring(tool or "unknown")
		if tool == "evidence" then return nil end
		local textValue, textTruncated = clip(text, M.limits.text)
		local dataText, dataTruncated
		if data ~= nil then
			local ok, encoded = pcall(util.encode, data)
			if ok and type(encoded) == "string" then dataText, dataTruncated = clip(encoded, M.limits.data) end
		end
		serial = serial + 1
		local recordId = string.format("ev-%d-%d", clock.ms(), serial)
		local record = { schema = 1, id = recordId, sessionId = id, tool = tool, at = clock.ms(),
			ok = not (info and info.ok == false), ms = info and info.ms or nil,
			text = textValue, textTruncated = textTruncated or nil,
			data = dataText, dataTruncated = dataTruncated or nil }
		local path = recordPath(id, recordId)
		if not path then return nil end
		local ok, why = fs.writeJson(path, record)
		if not ok then log.warn("evidence", "could not persist a tool result", why); return nil end
		local index = readIndex(id)
		index[#index + 1] = { id = recordId, tool = tool, at = record.at, ok = record.ok,
			bytes = #textValue + (dataText and #dataText or 0), preview = util.ellipsis(textValue, 1200) }
		local total = 0
		for _, entry in ipairs(index) do total = total + (entry.bytes or 0) end
		while #index > M.limits.records or total > M.limits.total do
			local old = table.remove(index, 1)
			if old then
				total = math.max(0, total - (old.bytes or 0))
				if old.id then pcall(fs.delete, recordPath(id, old.id)) end
			end
		end
		writeIndex(id, index)
		return recordId
	end

	local function summary(entry)
		return { id = entry.id, tool = entry.tool, at = entry.at, ok = entry.ok, bytes = entry.bytes,
			preview = entry.preview }
	end

	function M.list(session, args)
		args = args or {}
		local id = clean(session and session.id)
		if not id then return nil, "evidence is unavailable without a conversation identity" end
		local index = readIndex(id)
		local query = util.trim(tostring(args.query or "")):lower()
		local matched = {}
		for _, entry in ipairs(index) do
			if query == "" or tostring(entry.tool or ""):lower():find(query, 1, true)
				or tostring(entry.preview or ""):lower():find(query, 1, true) then
				matched[#matched + 1] = entry
			end
		end
		local offset = math.max(1, math.floor(tonumber(args.offset) or 1))
		local limit = math.max(1, math.min(math.floor(tonumber(args.limit) or 20), 50))
		local items, nextOffset = {}, nil
		for position = offset, math.min(#matched, offset + limit - 1) do
			items[#items + 1] = summary(matched[position])
		end
		if offset + #items <= #matched then nextOffset = offset + #items end
		return { items = items, total = #matched, offset = offset, nextOffset = nextOffset, eof = nextOffset == nil }
	end

	function M.read(session, recordId, section, args)
		args = args or {}
		local id = clean(session and session.id)
		if not id then return nil, "evidence is unavailable without a conversation identity" end
		if type(recordId) ~= "string" or recordId == "" then return nil, "record_id is required" end
		local path = recordPath(id, recordId)
		if not path then return nil, "invalid evidence record" end
		local record = fs.readJson(path, nil)
		if type(record) ~= "table" then return nil, "Evidence record was removed or never written." end
		section = section or "text"
		local text
		if section == "text" then text = tostring(record.text or "")
		elseif section == "data" then text = tostring(record.data or "")
		elseif section == "summary" then
			local rows = { "Record: " .. tostring(record.id), "Tool: " .. tostring(record.tool),
				"At: " .. tostring(record.at), "OK: " .. tostring(record.ok ~= false),
				"Text bytes: " .. tostring(#tostring(record.text or "")),
				"Data bytes: " .. tostring(#tostring(record.data or "")),
				"Text truncated: " .. tostring(record.textTruncated == true),
				"Data truncated: " .. tostring(record.dataTruncated == true) }
			text = table.concat(rows, "\n")
		else return nil, "unknown evidence section" end
		return { id = record.id, tool = record.tool, section = section, text = text,
			totalBytes = #text, truncated = section == "text" and record.textTruncated or (section == "data" and record.dataTruncated) or false }
	end

	function M.clear(session)
		local id = clean(session and session.id)
		if not id then return nil, "evidence is unavailable without a conversation identity" end
		local dir = directory(id)
		local files = fs.list(dir, {})
		if type(files) == "table" then
			for _, file in ipairs(files) do
				local path = type(file) == "table" and file.path or file
				if type(path) == "string" then pcall(fs.delete, dir .. "/" .. path:gsub("^.*/", "")) end
			end
		end
		return true
	end

	function M.state(session)
		local id = clean(session and session.id)
		if not id then return { enabled = M.enabled, records = 0, bytes = 0 } end
		local index = readIndex(id)
		local bytes = 0
		for _, entry in ipairs(index) do bytes = bytes + (entry.bytes or 0) end
		return { enabled = M.enabled, records = #index, bytes = bytes, limits = util.copy(M.limits) }
	end

	return M
end
