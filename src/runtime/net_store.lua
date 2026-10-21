-- Bounded records for captured HTTP calls and compiled chunks.
--
-- Records are append-only after completion. A captured body is stored as valid
-- UTF-8 text at a bounded size; the original byte count and hash are kept even
-- when the body was longer or had to be repaired.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local signal = env.require("runtime/signal")

	local M = { changed = signal.new("net-capture-records") }
	M.limits = {
		records = 500,
		bytes = 8 * 1024 * 1024,
		body = 256 * 1024,
		requestBody = 64 * 1024,
		chunk = 2 * 1024 * 1024,
		chunks = 32,
	}

	local records, index = {}, {}
	local first, last, bytes, sequence, chunks = 1, 0, 0, 0, 0
	local epoch = tostring(clock.ms())
	local counters = { admitted = 0, evicted = 0, truncated = 0, deduplicated = 0 }

	local function measure(record)
		record.bytes = #util.encode(record)
		return record.bytes
	end

	local function evict()
		while first <= last and (last - first + 1 > M.limits.records or bytes > M.limits.bytes or chunks > M.limits.chunks) do
			local old = records[first]
			records[first], first = nil, first + 1
			index[old.id] = nil
			bytes = math.max(0, bytes - (old.bytes or 0))
			if old.kind == "chunk" then chunks = math.max(0, chunks - 1) end
			counters.evicted = counters.evicted + 1
		end
		if first > 256 and first > last / 2 then
			local kept = {}
			for i = first, last do kept[#kept + 1] = records[i] end
			records, first, last = kept, 1, #kept
		end
	end

	local function notify(kind, id)
		M.changed:fire({ kind = kind, id = id, sequence = sequence })
	end

	function M.hash(text)
		local value = 5381
		for i = 1, #text do value = (value * 33 + text:byte(i)) % 4294967296 end
		return string.format("%08x", value)
	end

	function M.summary(record)
		if not record then return nil end
		local out = {
			id = record.id, sequence = record.sequence, revision = record.revision, kind = record.kind,
			at = record.at, sessionId = record.sessionId, thread = record.thread,
			method = record.method, url = record.url, host = record.host, path = record.path,
			status = record.status, outcome = record.outcome, durationMs = record.durationMs,
			requestBytes = record.requestBytes, responseBytes = record.responseBytes,
			bodyTruncated = record.bodyTruncated, binary = record.binary,
			suspectedCode = record.suspectedCode, alias = record.alias,
			name = record.name, bytes = record.sourceBytes or record.bytes,
			hash = record.hash, compileOk = record.compileOk, compileError = record.compileError,
			sourceTruncated = record.sourceTruncated, sourceBytes = record.sourceBytes,
			link = record.link, parentId = record.parentId, childId = record.childId,
			occurrences = record.occurrences, error = record.error, moduleId = record.moduleId,
			className = record.className, sourceStatus = record.sourceStatus,
		}
		return out
	end

	function M.add(record)
		sequence = sequence + 1
		record.sequence = sequence
		record.id = record.id or ("net:" .. epoch .. ":" .. sequence)
		record.at = record.at or clock.ms()
		record.revision = 1
		measure(record)
		last = last + 1
		records[last], index[record.id] = record, record
		bytes = bytes + record.bytes
		if record.kind == "chunk" then chunks = chunks + 1 end
		counters.admitted = counters.admitted + 1
		evict()
		notify("record", record.id)
		return record
	end

	function M.get(id)
		local record = index[id]
		if not record then return nil, "expired: capture record was cleared or evicted" end
		return record
	end

	function M.findChunk(hash, sessionId)
		for i = last, first, -1 do
			local record = records[i]
			if record.kind == "chunk" and record.hash == hash and (not sessionId or record.sessionId == sessionId) then return record end
		end
		return nil
	end

	function M.findParent(sessionId, thread, at, hash, windowMs)
		local fallback
		for i = last, first, -1 do
			local record = records[i]
			if record.kind == "http" and record.sessionId == sessionId and record.thread == thread
				and record.at <= at and not record.childId and (record.responseBytes or 0) > 0 then
				if record.bodyHash == hash then return record, "hash" end
				if not fallback and at - record.at <= (windowMs or 5000) then fallback = record end
			end
		end
		return fallback, fallback and "thread" or nil
	end

	function M.link(parentId, childId, link)
		local parent, child = index[parentId], index[childId]
		if not parent or not child then return false end
		parent.childId, parent.link = childId, link
		parent.revision = parent.revision + 1
		child.parentId, child.link = parentId, link
		child.revision = child.revision + 1
		measure(parent)
		notify("link", childId)
		return true
	end

	local function admitted(record, args)
		if args.kind and record.kind ~= args.kind then return false end
		if args.session_id and record.sessionId ~= args.session_id then return false end
		if args.host and record.host and not record.host:find(tostring(args.host):lower(), 1, true) then return false end
		if args.method and tostring(record.method or ""):upper() ~= tostring(args.method):upper() then return false end
		if args.url and not tostring(record.url or ""):lower():find(tostring(args.url):lower(), 1, true) then return false end
		if args.status and tonumber(record.status) ~= tonumber(args.status) then return false end
		if args.suspected == true and record.suspectedCode ~= true then return false end
		return true
	end

	function M.page(args)
		args = args or {}
		local after = tonumber(args.after_sequence) or 0
		local limit = math.max(1, math.min(math.floor(tonumber(args.limit) or 10), 20))
		local items, total, more = {}, 0, false
		for i = first, last do
			local record = records[i]
			if record.sequence > after and admitted(record, args) then
				total = total + 1
				if #items < limit then
					items[#items + 1] = M.summary(record)
				else
					more = true
				end
			end
		end
		local nextCursor = more and tostring(items[#items].sequence) or nil
		return { items = items, count = #items, total = total, retained = last - first + 1,
			nextCursor = nextCursor, afterSequence = after }
	end

	function M.read(id, section, args)
		local record, why = M.get(id)
		if not record then return nil, why end
		section = section or "summary"
		local text, extra
		if section == "summary" then
			local rows = {
				{ "Record", record.id }, { "Sequence", tostring(record.sequence) },
				{ "Kind", record.kind }, { "Session", tostring(record.sessionId) },
				{ "At", tostring(record.at) }, { "Outcome", tostring(record.outcome) },
			}
			if record.kind == "http" then
				rows[#rows + 1] = { "Request", tostring(record.method or "GET") .. " " .. tostring(record.url or "") }
				rows[#rows + 1] = { "Status", tostring(record.status or "?") }
				rows[#rows + 1] = { "Request bytes", tostring(record.requestBytes or 0) }
				rows[#rows + 1] = { "Response bytes", tostring(record.responseBytes or 0) }
				rows[#rows + 1] = { "Duration", string.format("%.0f ms", record.durationMs or 0) }
				if record.suspectedCode then rows[#rows + 1] = { "Code-like response", "yes; no chunk compiled" } end
			elseif record.kind == "chunk" then
				rows[#rows + 1] = { "Chunk", tostring(record.name or "loadstring") }
				rows[#rows + 1] = { "Source bytes", tostring(record.sourceBytes or 0) }
				rows[#rows + 1] = { "Hash", tostring(record.hash) }
				rows[#rows + 1] = { "Compiled", record.compileOk and "yes" or "no" }
				rows[#rows + 1] = { "Link", tostring(record.link or "none") }
			elseif record.kind == "module" then
				rows[#rows + 1] = { "Module", tostring(record.name or "") }
				rows[#rows + 1] = { "Source", tostring(record.sourceStatus or "unknown") }
			end
			if record.error then rows[#rows + 1] = { "Error", record.error } end
			local parts = {}
			for _, row in ipairs(rows) do parts[#parts + 1] = row[1] .. ": " .. row[2] end
			text = table.concat(parts, "\n")
			extra = M.summary(record)
		elseif section == "url" then
			text = tostring(record.url or "")
		elseif section == "request" then
			text = record.requestBody or ""
		elseif section == "response" then
			text = record.responseBody or ""
		elseif section == "chunk" or section == "module" then
			text = record.source or ""
			if text == "" and record.kind == "module" then text = tostring(record.name or "") end
		elseif section == "headers" then
			text = util.encode({ request = record.requestHeaders or {}, response = record.responseHeaders or {} })
		else
			return nil, "unknown section"
		end
		return { id = record.id, name = (record.name or record.url or record.id), section = section,
			text = text, totalBytes = #text, binary = record.binary == true,
			truncated = (section == "response" and record.bodyTruncated) or (section == "chunk" and record.sourceTruncated) or false,
			record = extra }, nil
	end

	function M.chain(args)
		args = args or {}
		local nodes, byId, children, roots = {}, {}, {}, {}
		for i = first, last do
			local record = records[i]
			if admitted(record, { session_id = args.session_id }) then
				local node = M.summary(record)
				nodes[#nodes + 1], byId[record.id] = node, node
				local parent = record.parentId
				if parent and byId[parent] then
					local list = children[parent] or {}
					list[#list + 1] = node
					children[parent] = list
				elseif parent and not byId[parent] then
					node.orphan = true
					roots[#roots + 1] = node
				else
					roots[#roots + 1] = node
				end
			end
		end
		local lines, seen, edges, shown = {}, {}, {}, 0
		local function label(node)
			if node.kind == "chunk" then
				return string.format("CHUNK %s (%d bytes, %s)%s", tostring(node.name or "loadstring"),
					node.sourceBytes or 0, tostring(node.hash), node.link and (" [" .. node.link .. "]") or "")
			elseif node.kind == "module" then
				return string.format("MODULE %s (%s)", tostring(node.name or ""), tostring(node.sourceStatus or "unknown"))
			end
			return string.format("HTTP %s %s -> %s (%d bytes)%s", tostring(node.method or "GET"), tostring(node.url or ""),
				tostring(node.status or "?"), node.responseBytes or 0, node.suspectedCode and " [code-like, not compiled]" or "")
		end
		local function visit(node, depth)
			if shown >= 120 or depth > 8 or seen[node.id] then return end
			seen[node.id], shown = true, shown + 1
			lines[#lines + 1] = string.rep("  ", depth) .. label(node)
			local list = children[node.id]
			if list then
				for _, child in ipairs(list) do
					edges[#edges + 1] = { parent = node.id, child = child.id, link = child.link }
					visit(child, depth + 1)
				end
			end
			if node.orphan then lines[#lines + 1] = string.rep("  ", depth) .. "  (parent was evicted)" end
		end
		for _, root in ipairs(roots) do visit(root, 0) end
		local text = #lines > 0 and table.concat(lines, "\n") or "No linked capture stages yet."
		if shown < #nodes then text = text .. "\n... " .. (#nodes - shown) .. " more not shown" end
		return { text = text, nodes = nodes, edges = edges, roots = roots, shown = shown, truncated = shown < #nodes }
	end

	function M.export(ids)
		local list = {}
		if type(ids) == "table" and #ids > 0 then
			for _, id in ipairs(ids) do
				local record = index[id]
				if record then list[#list + 1] = util.deepCopy(record) end
			end
		else
			for i = first, last do list[#list + 1] = util.deepCopy(records[i]) end
		end
		return list
	end

	function M.state()
		return { retained = last - first + 1, bytes = bytes, chunks = chunks, oldest = first <= last and records[first].sequence or nil,
			newest = first <= last and records[last].sequence or nil, counters = util.copy(counters), limits = util.copy(M.limits) }
	end

	function M.clear()
		records, index = {}, {}
		first, last, bytes, chunks = 1, 0, 0, 0
		notify("clear", nil)
		return M.state()
	end

	env.require("runtime/dispose").add(function() records, index = {}, {}; first, last, bytes, chunks = 1, 0, 0, 0 end, "network capture records")
	return M
end
