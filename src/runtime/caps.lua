-- What this host can actually do.
--
-- Every optional capability is probed exactly once, here, and the rest of the
-- project asks this module rather than testing for a global inline. That matters
-- for more than tidiness: the same script has to run under an executor with a
-- full filesystem, under one with only HTTP, and inside a plain client with
-- neither, and each of those has to degrade in a way the interface can explain
-- to the user instead of erroring.
return function(env)
	local M = {}
	-- Capability inspection must survive a deliberately broken host. The capture
	-- guard is optional here; without a loader there is no client traffic to mark.
	local guard = {
		enter = function() end, leave = function() end, active = function() return false end,
		run = function(fn, ...) return fn(...) end,
	}
	if type(env.require) == "function" then
		local ok, module = pcall(env.require, "runtime/capture_guard")
		if ok and type(module) == "table" then guard = module end
	end
	local unpackValues = table.unpack or unpack

	local function pack(...)
		return { n = select("#", ...), ... }
	end

	local function callable(value)
		return type(value) == "function" and value or nil
	end

	-- Executors disagree on where the HTTP function lives. Order matters only in
	-- that the bare global is the modern spelling.
	local function findRequests()
		local candidates = {
			{ name = "request", fn = callable(request) },
			{ name = "http_request", fn = callable(http_request) },
			{ name = "syn.request", fn = type(syn) == "table" and callable(syn.request) or nil },
			{ name = "http.request", fn = type(http) == "table" and callable(http.request) or nil },
			{ name = "fluxus.request", fn = type(fluxus) == "table" and callable(fluxus.request) or nil },
		}
		local found, seen = {}, {}
		for _, candidate in ipairs(candidates) do
			if candidate.fn and not seen[candidate.fn] then
				seen[candidate.fn] = true
				found[#found + 1] = candidate
			end
		end
		return found
	end

	local function findClipboard()
		return callable(setclipboard)
			or callable(toclipboard)
			or (type(syn) == "table" and callable(syn.write_clipboard))
			or nil
	end

	local requestAliases = findRequests()
	local primaryRequest = requestAliases[1]
	local requestFn, requestName = primaryRequest and primaryRequest.fn, primaryRequest and primaryRequest.name
	local compiler = callable(loadstring)
	if not compiler and callable(getgenv) then
		local ok, globals = pcall(getgenv)
		if ok and type(globals) == "table" then
			local readOk, candidate = pcall(function() return globals.loadstring end)
			if readOk then compiler = callable(candidate) end
		end
	end

	M.fn = {
		request = requestFn,
		readfile = callable(readfile),
		writefile = callable(writefile),
		appendfile = callable(appendfile),
		isfile = callable(isfile),
		isfolder = callable(isfolder),
		makefolder = callable(makefolder),
		listfiles = callable(listfiles),
		delfile = callable(delfile),
		delfolder = callable(delfolder),
		loadstring = compiler,
		getgenv = callable(getgenv),
		gethui = callable(gethui),
		clipboard = findClipboard(),
		identify = callable(identifyexecutor) or callable(getexecutorname),
		websocket = (type(WebSocket) == "table" and callable(WebSocket.connect))
			or (type(websocket) == "table" and callable(websocket.connect))
			or (type(syn) == "table" and type(syn.websocket) == "table" and callable(syn.websocket.connect)) or nil,
		getconnections = callable(getconnections),
		hookmetamethod = callable(hookmetamethod),
		getnamecallmethod = callable(getnamecallmethod),
		hookfunction = callable(hookfunction),
		newcclosure = callable(newcclosure),
		checkcaller = callable(checkcaller),
		getidentity = callable(getidentity) or callable(getthreadidentity),
		setidentity = callable(setidentity) or callable(setthreadidentity),
		getcallingscript = callable(getcallingscript),
		firesignal = callable(firesignal),
		fireclickdetector = callable(fireclickdetector),
		firetouchinterest = callable(firetouchinterest),
		getnilinstances = callable(getnilinstances),
		getinstances = callable(getinstances),
		getscripts = callable(getscripts),
		decompile = callable(decompile),
		getscriptbytecode = callable(getscriptbytecode),
		cloneref = callable(cloneref),
		queueTeleport = callable(queue_on_teleport),
		setfflag = callable(setfflag),
		customasset = callable(getcustomasset),
	}

	-- Raw executor functions stay available to capture hooks. The client calls the
	-- guarded wrappers, so its own compiles and requests never enter a capture
	-- record even when a wrapper is installed on the raw function.
	M.raw = { request = requestFn, loadstring = compiler, load = callable(load), require = callable(require), aliases = {} }
	for _, candidate in ipairs(requestAliases) do
		M.raw.aliases[#M.raw.aliases + 1] = { name = candidate.name, fn = candidate.fn }
	end
	local guardedFns = setmetatable({}, { __mode = "k" })
	local function guarded(fn)
		if type(fn) ~= "function" then return nil end
		local cached = guardedFns[fn]
		if cached then return cached end
		local wrapper = function(...)
			local args = pack(...)
			guard.enter()
			local returned = pack(pcall(fn, unpackValues(args, 1, args.n)))
			guard.leave()
			if not returned[1] then error(returned[2], 0) end
			return unpackValues(returned, 2, returned.n)
		end
		guardedFns[fn] = wrapper
		return wrapper
	end
	M.fn.request = guarded(requestFn)
	M.fn.loadstring = guarded(compiler)

	M.requestName = requestName

	-- Discovery may compare distinct native aliases without re-reading globals or
	-- changing the provider transport. Copies keep its captured inventory private.
	-- Guarded wrappers mark the client's own traffic as owned by this runtime.
	function M.requestAliases()
		local out = {}
		for _, candidate in ipairs(requestAliases) do
			out[#out + 1] = { name = candidate.name, fn = guarded(candidate.fn) }
		end
		return out
	end

	-- HTTP -------------------------------------------------------------------
	-- The executor path is preferred for one specific reason: RequestAsync
	-- refuses to send a User-Agent (along with Cookie, Host and Content-Length),
	-- so it physically cannot carry the Claude Code identity. When that is the
	-- only transport available the client says so rather than silently sending
	-- Roblox's own agent string.
	if M.fn.request then
		M.http = "executor"
		M.uaSupported = true
	else
		local ok, available = pcall(function()
			return env.services.HttpService ~= nil
		end)
		M.http = ok and available and "roblox" or "none"
		M.uaSupported = false
	end

	M.fs = (M.fn.writefile ~= nil and M.fn.readfile ~= nil)
	M.exec = M.fn.loadstring ~= nil
	M.ws = M.fn.websocket ~= nil
	M.clipboard = M.fn.clipboard ~= nil
	M.hui = M.fn.gethui ~= nil
	M.hooks = M.fn.getconnections ~= nil
	M.remoteHooks = {
		namecall = { state = M.fn.hookmetamethod and M.fn.getnamecallmethod and "available_unverified" or "unavailable" },
		direct = { state = M.fn.hookfunction and "available_unverified" or "unavailable" },
		invokeOutcomes = { state = "available_unverified", reason = "Requires a yielding native backend fixture" },
	}
	M.sourceRead = M.fn.decompile ~= nil or M.fn.getscripts ~= nil
		or (M.fn.getscriptbytecode ~= nil and M.fn.request ~= nil)

	-- Thread identity ----------------------------------------------------------
	-- The identity of the thread that boots the client. Some executors resume a
	-- thread scheduled by task.delay/task.spawn without it, and a write from such
	-- a thread into the interface -- which lives under gethui/CoreGui -- is then
	-- refused with "lacking capability Plugin". A signal fired from inside a
	-- remote hook arrives on a game-context thread, so anything it defers lands
	-- there; runtime/clock re-applies this identity before a scheduled callback
	-- runs so deferred client work keeps the context the client started with.
	M.identity = nil
	if M.fn.getidentity then
		local ok, value = pcall(M.fn.getidentity)
		if ok and type(value) == "number" then M.identity = value end
	end

	M.executor = "unknown"
	if M.fn.identify then
		local ok, name = pcall(M.fn.identify)
		if ok and type(name) == "string" and name ~= "" then M.executor = name end
	end

	do
		local ok, isStudio = pcall(function() return env.services.RunService:IsStudio() end)
		M.studio = ok and isStudio or false
	end

	do
		local ok, tenFoot = pcall(function() return env.services.GuiService:IsTenFootInterface() end)
		M.console = ok and tenFoot or false
	end

	M.available = {
		http = M.http ~= "none",
		fs = M.fs,
		exec = M.exec,
		ws = M.ws,
		clipboard = M.clipboard,
		hooks = M.hooks,
		capture = M.fn.hookfunction ~= nil,
		["ua"] = M.uaSupported,
	}

	-- Tools declare `needs = { "fs" }`; the registry checks the answer here
	-- before dispatch so an unavailable tool reports a clear reason to the model
	-- instead of erroring somewhere inside a nil call.
	function M.has(key)
		if key == "gravity" then return env.require("runtime/gravity").current() ~= nil end
		return M.available[key] == true
	end

	M.MISSING = {
		http = "no HTTP transport is available in this host",
		fs = "this host has no filesystem functions (writefile/readfile)",
		exec = "this host cannot compile code (loadstring is unavailable)",
		ws = "this host has no WebSocket support",
		clipboard = "this host has no clipboard function",
		hooks = "this host does not expose signal introspection (getconnections)",
		capture = "this host does not expose hookfunction, so network and payload capture cannot install hooks",
		ua = "this host cannot set a custom User-Agent",
		gravity = "Project Gravity is not connected; run the updated Gravity loader and open its PROJECT UAI button",
	}

	function M.reason(key)
		return M.MISSING[key] or ("capability '" .. tostring(key) .. "' is unavailable")
	end

	function M.summary()
		local parts = {
			"transport " .. M.http .. (M.requestName and (" (" .. M.requestName .. ")") or ""),
			"ua " .. (M.uaSupported and "yes" or "no"),
			"fs " .. (M.fs and "yes" or "no"),
			"exec " .. (M.exec and "yes" or "no"),
		}
		if M.executor ~= "unknown" then table.insert(parts, 1, M.executor) end
		return table.concat(parts, " | ")
	end

	return M
end
