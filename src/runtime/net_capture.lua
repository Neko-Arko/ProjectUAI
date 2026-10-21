-- Observe executor HTTP calls and compiled chunks without changing behaviour.
--
-- Every wrapper forwards to the function it replaced. Arguments and results are
-- never rewritten, errors are re-raised, and a failed recording is swallowed so
-- the target script still runs. Capture is a side channel, not a proxy.
return function(env)
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local guard = env.require("runtime/capture_guard")
	local store = env.require("runtime/net_store")
	local util = env.require("runtime/util")
	local signal = env.require("runtime/signal")

	local M = { changed = signal.new("net-capture"), status = "idle", revision = 0, reason = nil }
	local session, coverage, expiryGeneration, serial = nil, {}, 0, 0
	local hookProbe
	local unpackValues = table.unpack or unpack

	local MAIN = 0
	local threadIds = setmetatable({}, { __mode = "k" })
	local threadSerial = 0
	local function threadId()
		local thread = coroutine.running()
		if not thread then return MAIN end
		local id = threadIds[thread]
		if not id then threadSerial, id = threadSerial + 1, threadSerial; threadIds[thread] = id end
		return id
	end

	local SENSITIVE_HEADERS = {
		authorization = true, cookie = true, ["set-cookie"] = true, ["proxy-authorization"] = true,
		["x-api-key"] = true, ["api-key"] = true, ["x-auth-token"] = true, ["x-session-token"] = true,
		["x-csrf-token"] = true, token = true,
	}
	local SENSITIVE_QUERY = {
		token = true, access_token = true, api_key = true, apikey = true, key = true,
		secret = true, password = true, sig = true, signature = true, auth = true,
	}

	local function pack(...) return { n = select("#", ...), ... } end

	-- A pcall result needs its positions preserved: the first return may be nil
	-- (a failed compile), and a table constructor would move the error to index 1.
	local function resultPack(result)
		local out = { n = math.max(0, result.n - 1) }
		for index = 2, result.n do out[index - 1] = result[index] end
		return out
	end

	local function safeText(value)
		if type(value) ~= "string" then return "", false end
		return util.sanitise(value)
	end

	local function text(value)
		return (safeText(value))
	end

	local function cap(value, limit)
		local raw = type(value) == "string" and value or ""
		if #raw <= limit then return raw, false, #raw end
		return raw:sub(1, limit), true, #raw
	end

	local function redactHeaders(headers)
		local out, count = {}, 0
		if type(headers) ~= "table" then return out end
		for key, value in pairs(headers) do
			count = count + 1
			if count > 64 then break end
			local name = text(tostring(key))
			if #name > 128 then name = name:sub(1, 128) end
			local body = text(tostring(value))
			if SENSITIVE_HEADERS[name:lower()] then body = "<redacted>" elseif #body > 512 then body = body:sub(1, 512) end
			out[name] = body
		end
		return out
	end

	local function redactUrl(value)
		local url = text(tostring(value or ""))
		if #url > 2048 then url = url:sub(1, 2048) end
		local base, query = url:match("^([^?]*)(.*)$")
		if not query or query == "" then return url end
		local fragment = ""
		local hashAt = query:find("#", 1, true)
		if hashAt then fragment, query = query:sub(hashAt), query:sub(1, hashAt - 1) end
		query = query:gsub("^%?", "")
		local parts = {}
		for part in query:gmatch("[^&]+") do
			local key = part:match("^([^=]+)=")
			if key and SENSITIVE_QUERY[key:lower()] then parts[#parts + 1] = key .. "=<redacted>" else parts[#parts + 1] = part end
		end
		return base .. "?" .. table.concat(parts, "&") .. fragment
	end

	local function hostOf(url)
		local host = tostring(url or ""):match("^%a[%w+.-]*://([^/:?#]+)")
			or tostring(url or ""):match("^//([^/:?#]+)")
		return host and host:lower() or ""
	end

	local function pathOf(url)
		local rest = tostring(url or ""):match("^%a[%w+.-]*://[^/]+(.*)$") or ""
		rest = rest:gsub("[?#].*$", "")
		return rest ~= "" and rest or "/"
	end

	local function looksLikeCode(body)
		if type(body) ~= "string" or #body < 24 or body:find("\0", 1, true) then return false end
		local sample = math.min(#body, 512)
		local printable = 0
		for i = 1, sample do
			local byte = body:byte(i)
			if byte == 9 or byte == 10 or byte == 13 or (byte >= 32 and byte < 127) then printable = printable + 1 end
		end
		if printable / sample < 0.85 then return false end
		for _, marker in ipairs({ "loadstring", "game:GetService", "Instance.new", "local ", "return ", "require(", "pcall", "task.spawn", "function" }) do
			if body:find(marker, 1, true) then return true end
		end
		return false
	end

	local function hostMatches(host, filters)
		if type(filters) ~= "table" or #filters == 0 then return true end
		for _, filter in ipairs(filters) do
			local wanted = tostring(filter):lower():gsub("^%.", "")
			if wanted ~= "" and (host == wanted or host:sub(-(#wanted + 1)) == "." .. wanted) then return true end
		end
		return false
	end

	local function admitted(kind, method, host)
		if M.status ~= "running" then return false end
		if kind ~= "http" then return true end
		if session and session.filters then
			if not hostMatches(host or "", session.filters.host) then return false end
			if #session.filters.method > 0 then
				local wanted = tostring(method or "GET"):upper()
				local found = false
				for _, value in ipairs(session.filters.method) do if wanted == tostring(value):upper() then found = true; break end end
				if not found then return false end
			end
		end
		return true
	end

	local function emit()
		M.revision = M.revision + 1
		M.changed:fire({ status = M.status, revision = M.revision, sessionId = session and session.id or nil })
	end

	local function hookAvailable()
		if hookProbe ~= nil then return hookProbe end
		if type(caps.fn.hookfunction) ~= "function" then hookProbe = false; return false end
		local probe = function() return "uai-probe" end
		local ok, previous = pcall(caps.fn.hookfunction, probe, function() return "uai-hooked" end)
		if not ok or type(previous) ~= "function" then hookProbe = false; return false end
		pcall(caps.fn.hookfunction, probe, previous)
		hookProbe = true
		return true
	end
	M.hookAvailable = hookAvailable

	local function resolvePath(root, path)
		local node = root
		for part in tostring(path):gmatch("[^.]+") do
			if type(node) ~= "table" and type(node) ~= "userdata" then return nil end
			local ok, value = pcall(function() return node[part] end)
			if not ok then return nil end
			node = value
		end
		return node
	end

	local function discover(mode)
		local targets, byFn = {}, {}
		local function add(name, fn, kind, serviceMethod)
			if type(fn) ~= "function" then return end
			local existing = byFn[fn]
			if existing then
				if name ~= existing.name then existing.aliases[#existing.aliases + 1] = name end
				return
			end
			local target = { name = name, aliases = { name }, fn = fn, kind = kind, serviceMethod = serviceMethod, state = "unavailable" }
			byFn[fn] = target
			targets[#targets + 1] = target
		end
		local globals = caps.fn.getgenv and caps.fn.getgenv() or _G
		if mode == "http" or mode == "both" then
			local raw = caps.raw or {}
			for _, alias in ipairs(raw.aliases or {}) do add(alias.name, alias.fn, "request") end
			for _, entry in ipairs({
				{ "http_request", "http_request" }, { "syn.request", "syn.request" },
				{ "http.request", "http.request" }, { "fluxus.request", "fluxus.request" },
				{ "krnl.request", "krnl.request" }, { "weare.request", "weare.request" },
			}) do add(entry[1], resolvePath(globals, entry[2]), "request") end
			local function gameMethod(name)
				local ok, fn = pcall(function() return game[name] end)
				return ok and fn or nil
			end
			add("game:HttpGet", gameMethod("HttpGet"), "httpget")
			add("game:HttpGetAsync", gameMethod("HttpGetAsync"), "httpget")
			add("game:HttpPost", gameMethod("HttpPost"), "httppost")
			add("game:HttpPostAsync", gameMethod("HttpPostAsync"), "httppost")
			local hs = env.hs or env.services.HttpService
			if hs then
				add("HttpService:RequestAsync", hs.RequestAsync, "httpservice", "RequestAsync")
				add("HttpService:GetAsync", hs.GetAsync, "httpservice", "GetAsync")
				add("HttpService:PostAsync", hs.PostAsync, "httpservice", "PostAsync")
			end
		end
		if mode == "chunks" or mode == "both" then
			local raw = caps.raw or {}
			add("loadstring", raw.loadstring, "loadstring")
			add("loadstring (getgenv)", globals.loadstring, "loadstring")
			add("load", raw.load, "load")
			add("load (getgenv)", globals.load, "load")
			add("debug.loadstring", resolvePath(globals, "debug.loadstring"), "loadstring")
			add("require", raw.require or globals.require, "require")
			add("queue_on_teleport", globals.queue_on_teleport, "queued")
		end
		return targets
	end
	M.discover = discover

	local function install(target)
		local wrapper = function(...) return M.dispatch(target, ...) end
		local ok, previous = pcall(caps.fn.hookfunction, target.fn, wrapper)
		if not ok then target.state, target.reason = "failed", "hook installation failed" return false end
		if type(previous) ~= "function" then target.state, target.reason = "failed", "hookfunction returned no original function" return false end
		target.previous, target.state, target.reason = previous, "hooked", nil
		return true
	end

	local function parseRequest(target, args)
		local options, method, url, headers, body
		if target.kind == "request" then
			options = args[1]
		elseif target.kind == "httpservice" then
			if target.serviceMethod == "RequestAsync" then options = args[2]
			elseif target.serviceMethod == "GetAsync" then url, method = args[2], "GET"
			elseif target.serviceMethod == "PostAsync" then url, body, method = args[2], args[3], "POST" end
		elseif target.kind == "httpget" then
			local offset = type(args[1]) == "string" and 1 or 2
			url, headers, method = args[offset], args[offset + 1], "GET"
		elseif target.kind == "httppost" then
			local offset = type(args[1]) == "string" and 1 or 2
			url, body, headers, method = args[offset], args[offset + 1], args[offset + 2], "POST"
		end
		if type(options) == "table" then
			url = options.Url or options.url or url
			method = options.Method or options.method or method
			headers = options.Headers or options.headers or headers
			body = options.Body or options.body or body
		end
		if type(headers) ~= "table" then headers = {} end
		if type(url) ~= "string" then url = tostring(url or "") end
		method = tostring(method or "GET"):upper()
		if #method > 16 then method = method:sub(1, 16) end
		local encodedBody
		if type(body) == "string" then
			encodedBody = body
		elseif type(body) == "table" then
			local ok, value = pcall(util.encode, body)
			encodedBody = ok and value or ""
		elseif body ~= nil then
			encodedBody = tostring(body)
		end
		return { url = redactUrl(url), method = method, headers = headers, body = encodedBody or "", host = hostOf(url), path = pathOf(url) }
	end
	M.parseRequest = parseRequest

	function M.recordHttp(target, startedAt, thread, info, response, ok, problem)
		local status, body, headers = nil, "", {}
		if ok and type(response) == "table" then
			status = tonumber(response.StatusCode or response.Status)
			body = response.Body or response.ResponseData or ""
			headers = response.Headers or response.ResponseHeaders or {}
		elseif ok and type(response) == "string" then
			status, body = 200, response
		elseif not ok then
			status, body = nil, ""
		end
		if type(body) ~= "string" then body = tostring(body or "") end
		if type(headers) ~= "table" then headers = {} end
		local requestStored, requestTruncated, requestBytes = cap(info.body, store.limits.requestBody)
		local requestText = text(requestStored)
		local responseStored, responseTruncated, responseBytes = cap(body, store.limits.body)
		local responseText, responseBinary = safeText(responseStored)
		local record = {
			kind = "http", sessionId = session.id, thread = thread, at = startedAt, durationMs = clock.ms() - startedAt,
			alias = target.name, method = info.method, url = info.url, host = info.host, path = info.path,
			status = status, outcome = not ok and "errored" or (status and status >= 400) and "http_error" or "completed",
			error = problem and util.ellipsis(text(tostring(problem)), 500) or nil,
			requestHeaders = redactHeaders(info.headers), responseHeaders = redactHeaders(headers),
			requestBytes = requestBytes, requestBody = requestText, requestTruncated = requestTruncated,
			responseBytes = responseBytes, responseBody = responseText, bodyTruncated = responseTruncated,
			bodyHash = store.hash(body), binary = responseBinary,
			suspectedCode = not responseBinary and looksLikeCode(body) or nil,
		}
		if not admitted("http", info.method, info.host) then return nil end
		return store.add(record)
	end

	function M.recordChunk(target, startedAt, thread, args, result, problem)
		local source, name = args[1], args[2]
		if type(source) ~= "string" then
			if target.kind == "load" and type(source) == "function" then
				if not admitted("chunk") then return nil end
				return store.add({ kind = "chunk", sessionId = session.id, thread = thread, at = startedAt,
					name = "load(reader)", sourceStatus = "reader", source = "", sourceBytes = 0, compileOk = false,
					compileError = "load received a reader function; its bytes were not consumed" })
			end
			return nil
		end
		local hash = store.hash(source)
		local existing = store.findChunk(hash, session.id)
		if existing then
			existing.occurrences = (existing.occurrences or 1) + 1
			existing.lastAt = startedAt
			existing.revision = existing.revision + 1
			return existing
		end
		local stored, truncated = cap(source, store.limits.chunk)
		local body, binary = safeText(stored)
		local chunkName = type(name) == "string" and util.trim(name) ~= "" and util.ellipsis(text(name), 160) or "loadstring"
		local compileOk = result and type(result[1]) == "function"
		local compileError
		if not compileOk and result and result[2] ~= nil then compileError = util.ellipsis(text(tostring(result[2])), 500) end
		if problem then compileError = util.ellipsis(text(tostring(problem)), 500) end
		if not admitted("chunk") then return nil end
		local parent, link = store.findParent(session.id, thread, startedAt, hash, 5000)
		local record = store.add({ kind = "chunk", sessionId = session.id, thread = thread, at = startedAt,
			name = chunkName, source = body, sourceBytes = #source, sourceTruncated = truncated, hash = hash,
			binary = binary, compileOk = compileOk, compileError = compileError })
		if parent and record then store.link(parent.id, record.id, link) end
		return record
	end

	function M.recordModule(target, startedAt, thread, args, result, problem)
		if not admitted("chunk") then return nil end
		local targetArg = args[1]
		local name, className, moduleId, source, sourceStatus = "require", nil, nil, nil, "unavailable"
		if type(targetArg) == "number" then
			moduleId, name = tostring(targetArg), "rbxassetid://" .. tostring(targetArg)
		elseif typeof and typeof(targetArg) == "Instance" then
			local okName, value = pcall(function() return targetArg.Name end)
			if okName and value then name = tostring(value) end
			local okClass, class = pcall(function() return targetArg.ClassName end)
			if okClass and class then className = tostring(class) end
			local okId, value = pcall(function() return targetArg:GetFullName() end)
			if okId and value then moduleId = tostring(value) end
			if className == "ModuleScript" then
				local okSource, value = pcall(function() return targetArg.Source end)
				if okSource and type(value) == "string" and value ~= "" then source, sourceStatus = value, "readable" end
			end
		end
		if problem then sourceStatus = "require failed" end
		local hash = source and store.hash(source) or nil
		local parent, link
		if hash then parent, link = store.findParent(session.id, thread, startedAt, hash, 5000) end
		local stored, truncated, bytes = cap(source or "", store.limits.chunk)
		local body, binary = safeText(stored)
		local record = store.add({ kind = "module", sessionId = session.id, thread = thread, at = startedAt,
			name = util.ellipsis(text(name), 160), className = className, moduleId = moduleId,
			source = body, sourceBytes = bytes, sourceTruncated = truncated, hash = hash, binary = binary,
			sourceStatus = sourceStatus, compileOk = result and result[1] ~= nil or false,
			error = problem and util.ellipsis(text(tostring(problem)), 500) or nil })
		if parent and record then store.link(parent.id, record.id, link) end
		return record
	end

	function M.dispatch(target, ...)
		local previous = target.previous
		if type(previous) ~= "function" then return end
		if M.status ~= "running" or guard.active() then return previous(...) end
		local startedAt, thread = clock.ms(), threadId()
		local args = pack(...)
		local result = pack(pcall(previous, ...))
		if not result[1] then
			pcall(M.recordFailure, target, startedAt, thread, args, result[2])
			error(result[2], 0)
		end
		pcall(M.recordSuccess, target, startedAt, thread, args, result)
		return unpackValues(result, 2, result.n)
	end

	function M.recordSuccess(target, startedAt, thread, args, result)
		local returned = resultPack(result)
		if target.kind == "loadstring" or target.kind == "load" then
			M.recordChunk(target, startedAt, thread, args, returned)
		elseif target.kind == "queued" then
			if type(args[1]) == "string" and admitted("chunk") then
				local hash = store.hash(args[1])
				if not store.findChunk(hash, session.id) then
					local stored, truncated = cap(args[1], store.limits.chunk)
					local body = text(stored)
					store.add({ kind = "chunk", sessionId = session.id, thread = thread, at = startedAt,
						name = "queued_on_teleport", source = body, sourceBytes = #args[1], sourceTruncated = truncated,
						hash = hash, compileOk = false, compileError = "queued, not compiled in this session" })
				end
			end
		elseif target.kind == "require" then
			M.recordModule(target, startedAt, thread, args, returned)
		else
			M.recordHttp(target, startedAt, thread, parseRequest(target, args), result[2], true)
		end
	end

	function M.recordFailure(target, startedAt, thread, args, problem)
		if target.kind == "loadstring" or target.kind == "load" then
			M.recordChunk(target, startedAt, thread, args, nil, problem)
		elseif target.kind == "queued" then
			store.add({ kind = "chunk", sessionId = session.id, thread = thread, at = startedAt,
				name = "queue_on_teleport", source = "", sourceBytes = 0, compileOk = false,
				compileError = util.ellipsis(text(tostring(problem)), 500) })
		elseif target.kind == "require" then
			M.recordModule(target, startedAt, thread, args, nil, problem)
		else
			M.recordHttp(target, startedAt, thread, parseRequest(target, args), nil, false, problem)
		end
	end

	local function scheduleExpiry()
		expiryGeneration = expiryGeneration + 1
		local generation = expiryGeneration
		if M.status ~= "running" or not session or not session.expiresAt then return end
		local remaining = math.max(0, session.expiresAt - clock.ms())
		clock.delay(remaining / 1000, function()
			if generation ~= expiryGeneration or M.status ~= "running" or not session then return end
			if session.expiresAt and clock.ms() >= session.expiresAt then M.stop("duration reached") end
		end)
	end

	local function normaliseFilters(options)
		local hosts, methods = {}, {}
		if type(options.host) == "table" then
			for _, value in ipairs(options.host) do
				if type(value) == "string" and util.trim(value) ~= "" and #hosts < 16 then hosts[#hosts + 1] = value end
			end
		end
		if type(options.method) == "table" then
			for _, value in ipairs(options.method) do
				if type(value) == "string" and util.trim(value) ~= "" and #methods < 8 then methods[#methods + 1] = value:upper() end
			end
		end
		return { host = hosts, method = methods }
	end

	function M.start(options, ctx)
		options = options or {}
		if M.status == "running" then return nil, "A network capture is already running; stop it before starting another." end
		for _, target in ipairs(coverage) do
			if target.state == "retained" then
				return nil, "A previous capture could not restore " .. target.name .. "; reload the client before starting another capture."
			end
		end
		if not hookAvailable() then return nil, "This host cannot install function hooks safely (hookfunction did not return the original function)." end
		local mode = options.mode
		if mode ~= "http" and mode ~= "chunks" and mode ~= "both" then mode = "both" end
		local duration = tonumber(options.duration) or 120
		if duration < 1 or duration > 300 then duration = 120 end
		local targets = discover(mode)
		if #targets == 0 then return nil, "No capture target exists on this host for mode '" .. mode .. "'." end
		serial = serial + 1
		local startedAt = clock.ms()
		session = {
			id = "netcap:" .. tostring(startedAt) .. ":" .. serial,
			mode = mode,
			startedAt = startedAt,
			ownerSessionId = ctx and ctx.session and ctx.session.id or options.ownerSessionId,
			filters = normaliseFilters(options),
			expiresAt = options.persistent == true and nil or (startedAt + duration * 1000),
		}
		M.status, M.reason = "starting", nil
		coverage = targets
		local installed = 0
		for _, target in ipairs(targets) do if install(target) then installed = installed + 1 end end
		if installed == 0 then
			local reasons = {}
			for _, target in ipairs(targets) do reasons[#reasons + 1] = target.name .. ": " .. tostring(target.reason or "unavailable") end
			M.status, session = "idle", nil
			return nil, "Capture hooks could not be installed. " .. table.concat(reasons, "; ")
		end
		M.status = "running"
		M.revision = M.revision + 1
		scheduleExpiry()
		emit()
		return M.state()
	end

	function M.stop(reason)
		if M.status ~= "running" then return nil, "No network capture is running." end
		M.status = "stopping"
		for _, target in ipairs(coverage) do
			if target.state == "hooked" and type(target.previous) == "function" then
				local ok = pcall(caps.fn.hookfunction, target.fn, target.previous)
				target.state = ok and "restored" or "retained"
			end
		end
		M.status = reason == "duration reached" and "expired" or (reason == "revoked" and "revoked" or "stopped")
		M.reason = reason
		if session then session.stoppedAt = clock.ms() end
		expiryGeneration = expiryGeneration + 1
		M.revision = M.revision + 1
		emit()
		return M.state()
	end

	function M.revokeAgent(owner)
		if owner and session and session.ownerSessionId and owner ~= session.ownerSessionId then return false end
		if M.status == "running" then M.stop("revoked"); return true end
		return false
	end

	function M.state()
		local records = store.state()
		local targets = {}
		for _, target in ipairs(coverage) do
			targets[#targets + 1] = { name = target.name, aliases = util.copy(target.aliases), kind = target.kind,
				state = target.state, reason = target.reason }
		end
		local result = {
			status = M.status, sessionId = session and session.id or nil, revision = M.revision,
			mode = session and session.mode or nil, startedAt = session and session.startedAt or nil,
			expiresAt = session and session.expiresAt or nil, ownerSessionId = session and session.ownerSessionId or nil,
			filters = util.copy(session and session.filters or { host = {}, method = {} }),
			reason = M.reason, hookfunction = hookAvailable(),
			coverage = { targets = targets },
			retained = records.retained, bytes = records.bytes, chunks = records.chunks,
			oldest = records.oldest, newest = records.newest,
		}
		if result.expiresAt then result.remaining = math.max(0, (result.expiresAt - clock.ms()) / 1000) end
		return result
	end

	function M.coverageText()
		local state = M.state()
		local lines = { string.format("Capture %s%s%s", state.status,
			state.mode and (" (" .. state.mode .. ")") or "",
			state.remaining and string.format(" · %.0fs left", state.remaining) or "") }
		for _, target in ipairs(state.coverage.targets) do
			lines[#lines + 1] = string.format("  %s [%s] %s%s", target.name, target.kind, target.state,
				target.reason and (" — " .. target.reason) or "")
		end
		if state.retained then lines[#lines + 1] = string.format("Records: %d retained, %.1f KiB", state.retained, (state.bytes or 0) / 1024) end
		return table.concat(lines, "\n")
	end

	function M.export(args)
		args = args or {}
		local records = store.export(args.record_ids)
		if #records == 0 then return nil, "No capture records to export." end
		local envelope = { format = "uai-net-capture", version = 1, exportedAt = clock.ms(),
			placeId = game and game.PlaceId or nil, sessionId = session and session.id or nil, records = records }
		local encoded = util.encode(envelope)
		if #encoded > 2 * 1024 * 1024 then
			return nil, string.format("Capture export is %.1f MiB; select record_ids or clear the capture before exporting (2 MiB limit).", #encoded / 1048576)
		end
		local exports = env.require("runtime/native_exports")
		local destination = args.destination or ("exports/net-capture-" .. tostring(clock.ms()) .. ".json")
		local result, why = exports.write(encoded, destination)
		if not result then return nil, why end
		result.records, result.captureBytes = #records, #encoded
		return result
	end

	function M.clear()
		store.clear()
		M.revision = M.revision + 1
		emit()
		return M.state()
	end

	env.require("runtime/dispose").add(function()
		if M.status == "running" then M.stop("disposed") end
		coverage, session = {}, nil
	end, "network capture")
	return M
end
