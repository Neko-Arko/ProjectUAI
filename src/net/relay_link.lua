-- Discovers and pairs with the local inference relay (the mobile companion).
--
-- A phone's executor cuts long HTTP calls off after a wall-clock limit that a
-- reasoning turn easily exceeds. The companion is a tiny foreground service that
-- owns the upstream connection and answers every executor call in milliseconds.
-- This module finds it on loopback, pairs once for a stable token, and reports
-- whether it can be used. It performs no long work and never blocks boot.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local config = env.require("runtime/config")
	local dispose = env.require("runtime/dispose")
	local caps = env.require("runtime/caps")
	local http = env.require("net/http")
	local signal = env.require("runtime/signal")

	local M = { changed = signal.new("relay") }
	local alive, started, nextProbe, epoch = true, false, 0, 0
	local activeProbe, failures = nil, 0
	local verifiedToken, verifiedInstance, unlimited = nil, nil, false
	local state, lastError, lastProbeAt = "off", nil, 0
	local PROBE_MS = 30000

	local function mode()
		local value = config.get("relay.mode", "auto")
		if value ~= "auto" and value ~= "always" and value ~= "off" then return "auto" end
		return value
	end

	local function port()
		local value = tonumber(config.get("relay.port", 8790)) or 8790
		if value < 1 or value > 65535 or value % 1 ~= 0 then return 8790 end
		return value
	end

	local function token() return tostring(config.get("relay.token", "")) end
	local function base() return "http://127.0.0.1:" .. tostring(port()) end

	function M.mode() return mode() end

	-- Presentation and defaults only; the prober runs the same way everywhere.
	local function mobile()
		local ok, touch = pcall(function() return env.uis.TouchEnabled == true end)
		if not ok then return false end
		local okMouse, mouse = pcall(function() return env.uis.MouseEnabled end)
		return touch and (not okMouse or mouse ~= true)
	end
	function M.mobile() return mobile() end

	local function setState(next, note)
		if state == next and lastError == note then return end
		local previous = state
		state, lastError = next, note
		if next == "ready" then log.info("relay", "companion connected on port " .. tostring(port()))
		elseif next == "error" and previous == "ready" then log.warn("relay", "companion disconnected", note) end
		M.changed:fire()
	end

	local function remember(path, value)
		if config.get(path, "") ~= value then config.set(path, value, { quiet = true }) end
	end

	function M.status()
		return { mode = mode(), state = state, port = port(), server = tostring(config.get("relay.server", "")),
			instance = tostring(config.get("relay.instance", "")), placeId = tonumber(config.get("relay.placeId", 0)) or 0,
			error = lastError, lastProbeAt = lastProbeAt, unlimited = unlimited }
	end

	-- A periodic health check must not make a ready relay temporarily unusable or
	-- fill the log with an absent optional app. Settings and unload invalidate each
	-- request; a late hello/pair cannot restore credentials for an old endpoint.
	local function probe(mine, probeBase, probePort)
		local function stale() return not alive or epoch ~= mine or mode() == "off" end
		local hello = http.request({ url = probeBase .. "/api/hello", method = "GET",
			headers = token() ~= "" and { Authorization = "Bearer " .. token() } or nil,
			identity = "none", silent = true, timeout = 1, aborted = stale })
		if stale() then return false, "cancelled" end
		local info = hello and hello.ok and #hello.body <= 4096 and util.decode(hello.body)
		if type(info) ~= "table" or info.protocol ~= 2 or type(info.instance) ~= "string"
			or #info.instance == 0 or #info.instance > 128 then
			return false, "No companion answered on port " .. tostring(probePort)
		end
		-- Check the marker even when a token was saved from an earlier companion.
		if info.server ~= "uai-relay" then return false, "Port " .. tostring(probePort) .. " is used by another program" end
		local pairedToken = token()
		if pairedToken ~= "" and (pairedToken ~= verifiedToken or info.instance ~= verifiedInstance) then
			local status = http.request({ url = probeBase .. "/api/status", method = "GET",
				headers = { Authorization = "Bearer " .. pairedToken }, identity = "none", silent = true, timeout = 1, aborted = stale })
			if stale() then return false, "cancelled" end
			if status and status.status == 401 then pairedToken = ""
			else
				local checked = status and status.ok and #status.body <= 8192 and util.decode(status.body)
				if type(checked) ~= "table" or checked.ok ~= true or checked.server ~= "uai-relay"
					or checked.protocol ~= 2 or checked.instance ~= info.instance then
					return false, "The companion could not verify its saved pairing"
				end
			end
		end
		if pairedToken == "" then
			local place = env.require("runtime/place")
			local body = util.encode({ client = "ProjectUAI-Mobile",
				version = (env.info and env.info.version) or "0.0.0", protocol = 2,
				placeId = place.id, gameId = place.gameId })
			local pair = http.request({ url = probeBase .. "/api/pair", method = "POST", body = body,
				headers = { ["Content-Type"] = "application/json" }, identity = "none", silent = true, timeout = 2, aborted = stale })
			if stale() then return false, "cancelled" end
			local issued = pair and pair.ok and #pair.body <= 4096 and util.decode(pair.body)
			if type(issued) ~= "table" or issued.ok ~= true or type(issued.token) ~= "string"
				or #issued.token ~= 64 or not issued.token:match("^[a-f0-9]+$")
				or issued.protocol ~= 2 or issued.instance ~= info.instance then
				return false, "The companion refused pairing"
			end
			pairedToken = issued.token
			remember("relay.token", issued.token)
			remember("relay.server", "uai-relay")
			remember("relay.placeId", place.id)
		end
		verifiedToken, verifiedInstance = pairedToken, info.instance
		local inference = type(info.capabilities) == "table" and info.capabilities.inference
		unlimited = type(inference) == "table" and inference.schema == 1 and inference.unlimited == true
		remember("relay.instance", tostring(info.instance))
		return true
	end

	function M.probe()
		if not alive then return false, "unloaded" end
		if mode() == "off" then setState("off"); return false, "off" end
		if not caps.has("http") then
			nextProbe = clock.ms() + PROBE_MS
			setState("error", "no HTTP transport"); return false, "no HTTP transport"
		end
		if activeProbe then
			local pending = activeProbe
			while alive and pending == activeProbe and not pending.done do clock.wait(0.05) end
			if pending.done then return pending.ok == true, pending.reason end
			return false, not alive and "unloaded" or "cancelled"
		end
		local mine = epoch
		local pending = {}
		activeProbe = pending
		if state == "off" then setState("searching") end
		local ok, result, reason = pcall(probe, mine, base(), port())
		pending.ok, pending.reason, pending.done = ok and result == true, reason, true
		if not ok then pending.reason = "Companion probe failed" end
		if activeProbe == pending then activeProbe = nil end
		if alive and mine == epoch and mode() ~= "off" then
			lastProbeAt = clock.ms()
			failures = pending.ok and 0 or math.min(failures + 1, 3)
			nextProbe = lastProbeAt + PROBE_MS * 2 ^ math.max(0, failures - 1)
			setState(pending.ok and "ready" or "error", pending.reason)
		end
		return pending.ok, pending.reason
	end

	function M.usable()
		return alive and mode() ~= "off" and state == "ready" and token() ~= "" and caps.has("http")
	end

	function M.endpoint(retain)
		if retain then
			if not alive or mode() == "off" or token() == "" then return nil end
		elseif not M.usable() then return nil end
		return { target = "companion", base = base(), token = token(),
			instance = tostring(config.get("relay.instance", "")), enabled = true, unlimited = unlimited }
	end

	local function start()
		if started or not alive then return end
		started = true
		clock.spawn(function()
			while alive do
				if mode() ~= "off" and clock.ms() >= nextProbe then
					M.probe()
				end
				clock.wait(0.25)
			end
		end)
	end

	function M.ensure()
		if not alive then return end
		if mode() == "off" then setState("off"); return end
		start()
	end

	-- On-demand probe for a "Scan now" action.
	function M.scan()
		if mode() == "off" then return false, "off" end
		M.ensure()
		return M.probe()
	end

	-- Starting the app after Roblox should affect the next request, without
	-- waiting through discovery's two-minute idle backoff. One shared short scan
	-- is allowed per five seconds; absent apps cannot delay every provider retry.
	function M.prepare()
		if not mobile() or not alive or mode() == "off" or M.usable() then return end
		M.ensure()
		if activeProbe or lastProbeAt == 0 or clock.since(lastProbeAt) >= 5000 then M.probe() end
	end

	function M.forget()
		epoch, failures = epoch + 1, 0
		verifiedToken, verifiedInstance, unlimited = nil, nil, false
		remember("relay.token", "")
		remember("relay.server", "")
		remember("relay.instance", "")
		nextProbe = 0
		setState("searching")
	end

	dispose.add(config.changed:connect(function(path)
		if path ~= nil and path ~= "relay" and not util.startsWith(tostring(path), "relay.") then return end
		epoch, failures = epoch + 1, 0
		nextProbe = 0
		if path == "relay.port" then
			verifiedToken, verifiedInstance, unlimited = nil, nil, false
			remember("relay.token", "")
			remember("relay.server", "")
			remember("relay.instance", "")
		end
		setState(mode() == "off" and "off" or "searching")
		M.ensure()
		M.changed:fire()
	end), "relay settings")
	dispose.add(function() alive, epoch = false, epoch + 1 end, "relay prober")

	return M
end
