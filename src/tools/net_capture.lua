-- Network and payload capture: one lifecycle tool and one read tool.
--
-- The agent starts capture, runs the loader, then reads the recorded stages. It
-- never supplies hook code or a target function; the fixed hook set is chosen by
-- the runtime and reported in coverage.
return function(env)
	local capture = env.require("runtime/net_capture")
	local store = env.require("runtime/net_store")
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")
	local N = env.require("tools/native_helpers").forGroup("net_capture")
	local tools = {}

	local str = { type = "string" }
	local boolean = { type = "boolean" }
	local integer = { type = "integer", minimum = 1 }
	local hosts = { type = "array", items = str, maxItems = 16 }
	local methods = { type = "array", items = str, maxItems = 8 }
	local ids = { type = "array", items = str, maxItems = 100 }

	local watching
	local function watchRevocation()
		if watching then return end
		watching = true
		local registry = env.require("agent/registry")
		local permissions = env.require("agent/permissions")
		local config = env.require("runtime/config")
		local sessions = env.require("agent/session")
		local clock = env.require("runtime/clock")
		local previous = permissions.check({ name = "net_capture", risk = "write" })
		local alive = true
		local function check()
			local current = permissions.check({ name = "net_capture", risk = "write" })
			local state = capture.state()
			if state.status ~= "running" then previous = current; return end
			if not registry.groupEnabled("net_capture") or current == "deny" or (previous == "allow" and current ~= "allow") then
				capture.revokeAgent()
			else
				local owner = state.ownerSessionId
				if owner then
					local session = sessions.threads[owner]
					if not session or session.removed or session.abortFlag
						or (session.toolGroups and not session.toolGroups.net_capture)
						or (session.toolFilter and not session.toolFilter.net_capture)
						or (session.toolExclude and session.toolExclude.net_capture) then
						capture.revokeAgent(owner)
					end
				end
			end
			previous = current
		end
		local off = config.changed:connect(function(path)
			if path == nil or path == "agent" or path == "agent.disabledGroups" or tostring(path):match("^permissions") then check() end
		end)
		local offSession = sessions.anyEvent:connect(function(session, event) if event.kind == "abort" then capture.revokeAgent(session.id) end end)
		local offPermission = permissions.changed:connect(check)
		local function tick() if not alive then return end; check(); clock.delay(0.5, tick) end
		clock.delay(0.5, tick)
		env.require("runtime/dispose").add(function() alive = false; off(); offSession(); offPermission() end, "network capture authorization")
	end

	local function coverageSummary(state)
		local hooked, failed = 0, {}
		for _, target in ipairs(state.coverage.targets) do
			if target.state == "hooked" then hooked = hooked + 1
			elseif target.state == "failed" then failed[#failed + 1] = target.name .. ": " .. tostring(target.reason or "failed") end
		end
		local text = string.format("Capture %s: %d hook(s) active", state.status, hooked)
		if state.remaining then text = text .. string.format(", %.0fs left", state.remaining) end
		if #failed > 0 then text = text .. ". Failed: " .. table.concat(failed, "; ") end
		return text
	end

	local lifecycle = N.add(tools, "net_capture", "write",
		"Observe executor HTTP requests and executable chunks. Start before the target script runs, then use net_capture_read. Records method, URL (sensitive query values redacted), status, bounded request/response bodies, and loadstring/load/require source. UAI's own traffic is excluded. Stop restores hooks; a hook that cannot be restored is reported as retained and forwards without recording.",
		{
			action = { type = "string", enum = { "start", "stop", "status", "clear", "export" } },
			mode = { type = "string", enum = { "http", "chunks", "both" }, description = "Start only; default both." },
			host = hosts,
			method = methods,
			duration = { type = "number", minimum = 1, maximum = 300, description = "Seconds; default 120. Ignored when persistent=true." },
			persistent = boolean,
			destination = { type = "string", maxLength = 512 },
			record_ids = ids,
			session_id = str,
		}, { "action" }, function(args, ctx)
			if args.action == "start" then
				local data, why = capture.start({ mode = args.mode, host = args.host, method = args.method,
					duration = args.duration, persistent = args.persistent }, ctx)
				if not data then return N.fail(why) end
				watchRevocation()
				return N.result(data, coverageSummary(data) .. ". Run the loader now; UAI's own requests and compiles are not recorded.")
			elseif args.action == "stop" then
				local data, why = capture.stop("requested")
				if not data then return N.fail(why) end
				local retained, restored = 0, 0
				for _, target in ipairs(data.coverage.targets) do
					if target.state == "retained" then retained = retained + 1 end
					if target.state == "restored" then restored = restored + 1 end
				end
				return N.result(data, string.format("Capture stopped. %d record(s) retained; %d hook(s) restored%s.",
					data.retained or 0, restored, retained > 0 and (", " .. retained .. " retained and forwarding without recording") or ""))
			elseif args.action == "status" then
				local state = capture.state()
				return N.result(state, capture.coverageText())
			elseif args.action == "clear" then
				local state = capture.clear()
				return N.result(state, "Capture records cleared. The running capture, if any, continues.")
			elseif args.action == "export" then
				local data, why = capture.export({ record_ids = args.record_ids, destination = args.destination })
				if not data then return N.fail(why) end
				return N.result(data, string.format("Wrote %d capture record(s) to %s (%d bytes).",
					data.records or 0, tostring(data.path or "the workspace"), data.captureBytes or 0))
			end
			return N.fail("unknown action")
		end
	)
	lifecycle.risk = "write"
	lifecycle.needs = { "capture" }

	N.add(tools, "net_capture_read", "read",
		"Read captured network and payload records. list returns summaries with a continuation cursor; read pages one record's summary, URL, request, response, headers, chunk or module source; chain returns the HTTP -> chunk -> nested-request graph. Bodies and chunks are bounded; follow offsets. Payload bytes are never executed by this tool.",
		{
			action = { type = "string", enum = { "list", "read", "chain" } },
			kind = { type = "string", enum = { "http", "chunk", "module" } },
			host = str,
			method = str,
			url = str,
			status = { type = "integer", minimum = 100, maximum = 599 },
			suspected = boolean,
			after_sequence = { type = "integer", minimum = 0 },
			limit = { type = "integer", minimum = 1, maximum = 20 },
			record_id = str,
			section = { type = "string", enum = { "summary", "url", "request", "response", "headers", "chunk", "module" } },
			offset = integer,
			bytes = { type = "integer", minimum = 200, maximum = 64000, description = "Read page size; default 4000." },
			session_id = str,
		}, { "action" }, function(args, ctx)
			if args.action == "list" then
				local data = store.page(args)
				local lines = {}
				for index, item in ipairs(data.items) do
					if item.kind == "http" then
						lines[#lines + 1] = string.format("%d. #%d HTTP %s %s -> %s (%d B)%s [%s]",
							index, item.sequence, tostring(item.method or "GET"), tostring(item.url or ""),
							tostring(item.status or "?"), item.responseBytes or 0,
							item.suspectedCode and " code-like" or "", item.id)
					elseif item.kind == "module" then
						lines[#lines + 1] = string.format("%d. #%d MODULE %s (%s)%s [%s]", index, item.sequence,
							tostring(item.name or ""), tostring(item.sourceStatus or "unknown"),
							item.sourceBytes and (" " .. item.sourceBytes .. " B") or "", item.id)
					else
						lines[#lines + 1] = string.format("%d. #%d CHUNK %s (%d B%s)%s [%s]", index, item.sequence,
							tostring(item.name or "loadstring"), item.sourceBytes or 0,
							item.compileOk and "" or ", not compiled", item.link and (" · " .. item.link) or "", item.id)
					end
				end
				local text = #lines > 0 and table.concat(lines, "\n") or "No matching capture records."
				if data.nextCursor then text = text .. "\nnextCursor=" .. data.nextCursor end
				return N.result(data, text)
			elseif args.action == "read" then
				if not args.record_id then return N.fail("record_id is required for read") end
				local section = args.section or "summary"
				local page, why = store.read(args.record_id, section, args)
				if not page then return N.fail(why) end
				local result = H.readSlice(page.name, page.text, { offset = args.offset, limit = args.bytes }, 4000)
				result.data = result.data or {}
				result.data.recordId, result.data.section = page.id, section
				result.data.totalBytes, result.data.binary, result.data.truncated = page.totalBytes, page.binary, page.truncated
				result.data.record = page.record
				return result
			elseif args.action == "chain" then
				local data = store.chain(args)
				return N.result(data, data.text)
			end
			return N.fail("unknown action")
		end)

	env.require("tools/native_helpers").addReader(tools, "net_capture")
	return tools
end
