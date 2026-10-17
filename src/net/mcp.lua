-- External harnesses use the same dispatcher and permissions as the native agent.
-- Sessions belong to one authenticated bridge connection, never the active chat.
return function(env)
	local sessions = env.require("agent/session")
	local registry = env.require("agent/registry")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local M = {}
	local owners, closed, closedOrder = {}, {}, {}
	local cancelled, cancelledOrder = {}, {}
	local total = 0
	local function identifier(value)
		return type(value) == "string" and #value > 0 and #value <= 96 and value:match("^[%w_-]+$")
	end
	local function rememberClosed(id)
		if closed[id] then return end
		closed[id] = true
		closedOrder[#closedOrder + 1] = id
		if #closedOrder > 256 then closed[table.remove(closedOrder, 1)] = nil end
	end
	local function ownerFor(id, label)
		if closed[id] then error("MCP session is closed; reconnect your harness", 0) end
		if owners[id] then return owners[id] end
		if total >= 32 then error("Too many MCP sessions; close an unused harness connection", 0) end
		local session, why = sessions.newThread({ title = "MCP · " .. util.ellipsis(tostring(label or "External harness"), 64),
			ephemeral = true, activate = false })
		if not session then error(why, 0) end
		local owner = { session = session, calls = {}, completed = {}, pending = 0, bytes = 0, count = 0 }
		owners[id], total = owner, total + 1
		return owner
	end
	local function cancel(owner, id)
		local call = owner and owner.calls[id]
		if call then call.cancelled = true end
		return call ~= nil
	end
	function M.close(id)
		if not identifier(id) then error("Invalid MCP session identity", 0) end
		rememberClosed(id)
		local owner = owners[id]
		if not owner then return { closed = true } end
		owners[id], total = nil, total - 1
		for _, call in pairs(owner.calls) do call.cancelled = true end
		-- remove() releases pending approvals, descendants, capture and owned inputs.
		sessions.remove(owner.session.id)
		return { closed = true }
	end
	function M.clear()
		local ids = {}
		for id in pairs(owners) do ids[#ids + 1] = id end
		for _, id in ipairs(ids) do M.close(id) end
		cancelled, cancelledOrder = {}, {}
	end
	function M.run(command)
		local id = command.mcpSessionId
		if not identifier(id) then error("Invalid MCP session identity", 0) end
		if command.type == "mcp:close" then return M.close(id) end
		if not identifier(command.callId) then error("Invalid MCP call identity", 0) end
		if command.type == "mcp:cancel" then
			local owner = owners[id]
			-- Cancellation can arrive before its queued dispatch coroutine starts.
			local key = id .. ":" .. command.callId
			if not cancelled[key] then
				cancelled[key] = true
				cancelledOrder[#cancelledOrder + 1] = key
				if #cancelledOrder > 256 then cancelled[table.remove(cancelledOrder, 1)] = nil end
			end
			cancel(owner, command.callId)
			return { cancelled = true }
		end
		if command.type ~= "mcp:call" then error("Unknown MCP command", 0) end
		if cancelled[id .. ":" .. command.callId] then
			return { ok = false, error = "aborted", text = "MCP call was cancelled before dispatch." }
		end
		if type(command.name) ~= "string" or #command.name > 160 or command.name == "" then error("Invalid MCP tool name", 0) end
		if command.arguments ~= nil and (type(command.arguments) ~= "table" or (#command.arguments > 0)) then
			error("MCP arguments must be an object", 0)
		end
		local arguments = util.encode(command.arguments or util.emptyObject())
		if #arguments > 256000 then error("MCP arguments exceed the tool input limit", 0) end
		local owner = ownerFor(id, command.clientName)
		local session = owner.session
		if session.removed then error("MCP conversation was removed; reconnect your harness", 0) end
		local existing = owner.calls[command.callId]
		if existing then
			if existing.expired then error("MCP receipt expired; inspect Roblox before repeating this action", 0) end
			if existing.name and (existing.name ~= command.name or existing.arguments ~= arguments) then error("MCP call identity was reused with different arguments", 0) end
			while existing.running do clock.wait(0.05) end
			if existing.expired then error("MCP receipt expired; inspect Roblox before repeating this action", 0) end
			return existing.result or { ok = false, error = "aborted", text = "MCP call was cancelled before dispatch." }
		end
		if owner.pending >= 8 then error("This MCP session already has eight active tools", 0) end
		if owner.count >= 512 then error("MCP call history is full; reconnect this harness", 0) end
		if session.preparing or (session.busy and owner.pending == 0) then error("MCP conversation is busy", 0) end
		-- A connection spans many tool requests. Keep its epoch so a later call
		-- can inspect/stop work started by an earlier one (capture, input, loops).
		-- Manual Stop already invalidates the old epoch inside session.abort().
		if owner.pending == 0 then session.abortFlag = false end
		local call = { name = command.name, arguments = arguments, running = true, cancelled = false }
		owner.calls[command.callId] = call
		owner.count = owner.count + 1
		owner.pending = owner.pending + 1
		session.busy = true
		sessions.listChanged:fire()
		local context = session.toolContext()
		local originallyAborted = context.aborted
		context.aborted = function() return call.cancelled or owners[id] ~= owner or originallyAborted() end
		local emit = context.emit
		context.emit = function(kind, payload) if not context.aborted() then emit(kind, payload) end end
		session.emit("tool:call", { id = command.callId, name = command.name, arguments = arguments })
		local ok, result = pcall(registry.dispatch, { id = command.callId, name = command.name, arguments = arguments }, context)
		if not ok then result = { id = command.callId, name = command.name, ok = false, error = "dispatch failed", text = tostring(result) } end
		session.emit(result.ok and "tool:result" or "tool:error", result)
		local answer = { id = result.id, name = result.name, ok = result.ok == true,
			text = util.truncate(result.modelText or result.text or "", 128000), error = result.error, ms = result.ms }
		if type(result.data) == "table" and #util.encode(result.data) <= 64000 then answer.data = result.data end
		call.running, call.result = false, answer
		call.bytes = #arguments + #util.encode(answer)
		owner.bytes = owner.bytes + call.bytes
		owner.pending = owner.pending - 1
		owner.completed[#owner.completed + 1] = command.callId
		while #owner.completed > 32 or owner.bytes > 2 * 1024 * 1024 do
			local oldId = table.remove(owner.completed, 1)
			local old = owner.calls[oldId]
			owner.bytes = owner.bytes - old.bytes
			-- Keep the identity after eviction so it cannot become a new mutation.
			old.expired, old.arguments, old.result, old.bytes = true, nil, nil, nil
		end
		if owner.pending == 0 then
			session.busy = false
			session.emit("status", { text = "Ready" })
		end
		sessions.listChanged:fire()
		return answer
	end
	env.require("runtime/dispose").add(M.clear, "MCP sessions")
	return M
end
