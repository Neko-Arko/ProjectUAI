-- Durable tool evidence, kept outside the conversation context.
--
-- Writing is deliberately off the tool's critical path. Large results are queued
-- in memory, coalesced into short batches, and flushed after a small delay. A
-- fast model can therefore produce many results without synchronous filesystem
-- writes between them; the queue is bounded and drops new entries under pressure
-- rather than risking the client.
return function(env)
	local fs = env.require("runtime/fsx")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local config = env.require("runtime/config")

	local M = { enabled = fs.enabled ~= false, root = "evidence" }
	M.limits = { records = 200, text = 256 * 1024, data = 256 * 1024, total = 16 * 1024 * 1024 }
	M.queueLimits = { items = 64, bytes = 4 * 1024 * 1024, batchItems = 8, batchBytes = 2 * 1024 * 1024, delay = 0.2 }
	M.stats = { written = 0, dropped = 0, failed = 0, queued = 0 }

	local serial, queue, queueBytes = 0, {}, 0
	local indexes, totals, hashes, loaded = {}, {}, {}, {}
	local scheduled = false

	-- These either already have a durable home or are not worth a ledger entry.
	local SKIP = {
		evidence = true, evidence_clear = true, tool_search = true, support_bundle = true,
		file_read = true, file_read_many = true, file_list = true, file_search = true, file_find = true,
		code_read = true, code_search = true, code_tabs = true,
		conversation_read = true, conversation_search = true,
		memory_read = true, memory_write = true, todo_read = true,
		skills_list = true, skills_read = true,
		net_capture_read = true, remote_capture_read = true,
	}

	function M.hash(text)
		local value = 5381
		for index = 1, #text do value = (value * 33 + text:byte(index)) % 4294967296 end
		return string.format("%08x", value)
	end

	local function policy()
		local mode = tostring(config.get("agent.evidence", "large"))
		if mode ~= "all" and mode ~= "off" then mode = "large" end
		local minimum = tonumber(config.get("agent.evidenceMinBytes", 8192)) or 8192
		if minimum < 1024 then minimum = 1024 end
		if minimum > 1024 * 1024 then minimum = 1024 * 1024 end
		return mode, math.floor(minimum)
	end
	M.policy = policy

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

	local function indexFor(session)
		local id = clean(session)
		if not id then return nil end
		if not loaded[id] then
			local value = fs.readJson(indexPath(id), {})
			indexes[id] = type(value) == "table" and value or {}
			hashes[id], totals[id] = {}, 0
			for _, entry in ipairs(indexes[id]) do
				totals[id] = totals[id] + (entry.bytes or 0)
				if type(entry.preview) == "string" and #entry.preview > 200 then
					entry.preview = util.ellipsis(entry.preview, 200)
				end
				if type(entry.hash) == "string" then hashes[id][entry.hash] = entry.id end
			end
			loaded[id] = true
		end
		return indexes[id]
	end

	local function prune(session, index, total)
		while #index > M.limits.records or total > M.limits.total do
			local old = table.remove(index, 1)
			if not old then break end
			total = math.max(0, total - (old.bytes or 0))
			if old.hash and hashes[session] then hashes[session][old.hash] = nil end
			if old.id then pcall(fs.delete, recordPath(session, old.id)) end
		end
		return total
	end

	local flush
	local function schedule()
		if scheduled then return end
		scheduled = true
		clock.delay(M.queueLimits.delay, function()
			scheduled = false
			local ok, why = pcall(flush)
			if not ok then
				M.stats.failed = M.stats.failed + 1
				log.warn("evidence", "queued evidence flush failed", why)
			end
		end)
	end

	local function cost(item)
		return #item.text + (item.data and #item.data or 0) + 512
	end

	flush = function()
		if #queue == 0 then return end
		local batch, batchBytes = {}, 0
		while #queue > 0 and #batch < M.queueLimits.batchItems do
			local item = queue[1]
			local itemBytes = cost(item)
			if #batch > 0 and batchBytes + itemBytes > M.queueLimits.batchBytes then break end
			table.remove(queue, 1)
			queueBytes = math.max(0, queueBytes - itemBytes)
			batch[#batch + 1] = item
			batchBytes = batchBytes + itemBytes
		end
		local dirty = {}
		for _, item in ipairs(batch) do
			local path = recordPath(item.sessionId, item.id)
			local ok = false
			if path then
				local record = { schema = 1, id = item.id, sessionId = item.sessionId, tool = item.tool, at = item.at,
					ok = item.ok, ms = item.ms, text = item.text, textTruncated = item.textTruncated or nil,
					data = item.data, dataTruncated = item.dataTruncated or nil, hash = item.hash }
				ok = fs.writeJson(path, record)
			end
			if ok then
				local index = indexFor(item.sessionId)
				if index then
					index[#index + 1] = { id = item.id, tool = item.tool, at = item.at, ok = item.ok, hash = item.hash,
						bytes = item.bytes, preview = util.ellipsis(item.text, 200) }
					totals[item.sessionId] = prune(item.sessionId, index, (totals[item.sessionId] or 0) + item.bytes)
					hashes[item.sessionId][item.hash] = item.id
					dirty[item.sessionId] = true
					M.stats.written = M.stats.written + 1
				end
			else
				M.stats.failed = M.stats.failed + 1
			end
		end
		for session in pairs(dirty) do
			local ok, why = fs.writeJson(indexPath(session), indexes[session])
			if not ok then log.warn("evidence", "could not persist the evidence index", why) end
		end
		if #queue > 0 then schedule() end
	end
	M.flush = flush

	local function enqueue(item)
		local itemBytes = cost(item)
		if #queue >= M.queueLimits.items or queueBytes + itemBytes > M.queueLimits.bytes then
			M.stats.dropped = M.stats.dropped + 1
			return false
		end
		queue[#queue + 1] = item
		queueBytes = queueBytes + itemBytes
		M.stats.queued = #queue
		schedule()
		return true
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
		if SKIP[tool] then return nil end
		local mode, minimum = policy()
		if mode == "off" then return nil end
		local textValue, textTruncated = clip(text, M.limits.text)
		-- Do not encode a large structured result only to drop it because the
		-- write queue is already full.
		if #queue >= M.queueLimits.items or queueBytes >= M.queueLimits.bytes then
			M.stats.dropped = M.stats.dropped + 1
			return nil
		end
		local dataText, dataTruncated
		if data ~= nil then
			local ok, encoded = pcall(util.encode, data)
			if ok and type(encoded) == "string" then dataText, dataTruncated = clip(encoded, M.limits.data) end
		end
		local bytes = #textValue + (dataText and #dataText or 0)
		if mode ~= "all" and bytes < minimum then return nil end
		local hash = M.hash(textValue .. "\0" .. (dataText or ""))
		local index = indexFor(id)
		if index and hashes[id][hash] then return hashes[id][hash] end
		for _, item in ipairs(queue) do
			if item.sessionId == id and item.hash == hash then return item.id end
		end
		serial = serial + 1
		local recordId = string.format("ev-%d-%d", clock.ms(), serial)
		if not enqueue({ sessionId = id, id = recordId, tool = tool, at = clock.ms(),
			ok = not (info and info.ok == false), ms = info and info.ms or nil,
			text = textValue, textTruncated = textTruncated, data = dataText, dataTruncated = dataTruncated,
			hash = hash, bytes = bytes }) then
			return nil
		end
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
		flush()
		local index = indexFor(id) or {}
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
		flush()
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
		for position = #queue, 1, -1 do
			if queue[position].sessionId == id then
				queueBytes = math.max(0, queueBytes - cost(queue[position]))
				table.remove(queue, position)
			end
		end
		M.stats.queued = #queue
		indexes[id], totals[id], hashes[id], loaded[id] = nil, nil, nil, nil
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
		local mode, minimum = policy()
		local id = clean(session and session.id)
		if not id then return { enabled = M.enabled, records = 0, bytes = 0, mode = mode, minBytes = minimum } end
		flush()
		local index = indexFor(id) or {}
		local bytes = 0
		for _, entry in ipairs(index) do bytes = bytes + (entry.bytes or 0) end
		return { enabled = M.enabled, records = #index, bytes = bytes, limits = util.copy(M.limits),
			mode = mode, minBytes = minimum, pending = #queue, stats = util.copy(M.stats) }
	end

	env.require("runtime/dispose").add(function()
		if #queue > 0 then pcall(flush) end
		queue, queueBytes, scheduled = {}, 0, false
		indexes, totals, hashes, loaded = {}, {}, {}, {}
	end, "evidence queue")
	return M
end
