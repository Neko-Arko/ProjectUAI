-- Redacted, local-only diagnostics for a support report.
--
-- This is deliberately not a full configuration export: API keys, authorization
-- values, conversation text, file contents and captured payloads are excluded.
return function(env)
	local util = env.require("runtime/util")
	local log = env.require("runtime/log")
	local clock = env.require("runtime/clock")
	local config = env.require("runtime/config")

	local M = { format = "uai-support", version = 1 }
	local caps

	local SECRET_KEYS = {
		apikey = true, key = true, token = true, accesstoken = true, refreshtoken = true,
		password = true, secret = true, clientsecret = true, authorization = true,
		cookie = true, setcookie = true, xapikey = true, proxyauthorization = true,
		subscribe = true, webhook = true,
	}

	local function secretKey(key)
		local clean = tostring(key):lower():gsub("[_%-%s]", "")
		return SECRET_KEYS[clean] == true
	end

	local function redactHeaderTable(headers)
		local out = {}
		if type(headers) ~= "table" then return out end
		for key in pairs(headers) do out[key] = "<redacted>" end
		return out
	end

	local function redactTree(value, depth)
		if depth > 12 then return "<depth limit>" end
		local kind = type(value)
		if kind == "string" then return log.redact(value)
		elseif kind == "number" or kind == "boolean" or kind == "nil" then return value
		elseif kind ~= "table" then return "<" .. kind .. ">" end
		local out = {}
		for key, item in pairs(value) do
			if type(key) == "string" and secretKey(key) then out[key] = "<redacted>"
			else out[redactTree(key, depth + 1)] = redactTree(item, depth + 1) end
		end
		return out
	end

	local function safely(fn, fallback)
		local ok, value = pcall(fn)
		return ok and value or fallback
	end

	local function providerSummary(record)
		local health = record.health or {}
		return {
			id = record.id, label = record.label, baseUrl = log.redact(tostring(record.baseUrl or "")),
			model = record.model, api = record.api, enabled = record.enabled ~= false, order = record.order,
			health = { ok = health.ok or 0, fail = health.fail or 0, streak = health.streak or 0,
				lastMs = health.lastMs or 0, cooldownUntil = health.cooldownUntil or 0,
				lastError = health.lastError and log.redact(health.lastError) or nil },
			toolsCap = record.toolsCap,
		}
	end

	local function sessionsSummary()
		local sessions = safely(function() return env.require("agent/session") end, nil)
		if not sessions then return { available = false } end
		local out = {}
		local current = sessions.activeId and sessions.threads and sessions.threads[sessions.activeId] or nil
		for _, session in ipairs(safely(function() return sessions.list() end, {})) do
			out[#out + 1] = { id = session.id, title = session.title, busy = session.busy == true,
				removed = session.removed == true, model = session.model,
				messages = type(session.messages) == "table" and #session.messages or 0,
				updatedAt = session.updatedAt }
		end
		return { available = true, currentId = current and current.id or nil, count = #out, items = out }
	end

	local function toolsSummary()
		local registry = safely(function() return env.require("agent/registry") end, nil)
		if not registry then return { available = false } end
		local stats = safely(function() return registry.stats() end, {})
		local groups = {}
		for _, group in ipairs(safely(function() return registry.groups() end, {})) do
			groups[#groups + 1] = { id = group.id, label = group.label, enabled = group.enabled, total = group.total }
		end
		return { available = true, stats = stats, groups = groups, profile = config.get("agent.toolProfile", "all") }
	end

	local function httpSummary()
		local ok, http = pcall(env.require, "net/http")
		if not ok or not http or type(http.history) ~= "table" then return { available = false } end
		local out = {}
		local first = math.max(1, #http.history - 29)
		for index = first, #http.history do
			local entry = http.history[index]
			out[#out + 1] = { at = entry.at, method = entry.method, url = entry.url, status = entry.status,
				ms = entry.ms, bytes = entry.bytes, via = entry.via, identity = entry.identity,
				uaSent = entry.uaSent, error = entry.error, server = entry.server, trace = entry.trace,
				mitigated = entry.mitigated, tag = entry.tag }
		end
		return { available = true, count = http.count or #http.history, items = out }
	end

	local function placeSummary()
		local workspace = safely(function() return env.require("runtime/workspace").describe() end, {})
		return { placeId = game and game.PlaceId, gameId = game and game.GameId, placeVersion = game and game.PlaceVersion,
			name = workspace.displayName, root = workspace.root, files = workspace.path }
	end

	local function uiSummary()
		local viewport = safely(function() return env.services.Workspace.CurrentCamera.ViewportSize end, nil)
		local gui = safely(function() return env.guisvc:IsTenFootInterface() end, false)
		return { viewport = viewport and { x = viewport.X, y = viewport.Y } or nil,
			touch = safely(function() return env.uis.TouchEnabled end, nil),
			mouse = safely(function() return env.uis.MouseEnabled end, nil),
			keyboard = safely(function() return env.uis.KeyboardEnabled end, nil),
			console = caps and caps.console or gui, studio = caps and caps.studio or nil,
			layout = config.get("ui.layout"), theme = config.get("ui.theme"), textScale = config.get("ui.textScale") }
	end

	function M.build()
		caps = safely(function() return env.require("runtime/caps") end, nil)
		local providerList = {}
		for _, record in ipairs(safely(function() return config.get("providers.list", {}) end, {})) do
			if type(record) == "table" then providerList[#providerList + 1] = providerSummary(record) end
		end
		local permissions = safely(function() return env.require("agent/permissions") end, nil)
		local httpSection = httpSummary()
		local logs = safely(function() return log.tail(120) end, {})
		local safeConfig = redactTree(config.data or {}, 0)
		if type(safeConfig.agent) == "table" then safeConfig.agent.customInstructions = "<omitted>" end
		if type(safeConfig.memory) == "table" then safeConfig.memory.entries = "<omitted>" end
		if type(safeConfig.identity) == "table" and type(safeConfig.identity.extraHeaders) == "table" then
			safeConfig.identity.extraHeaders = redactHeaderTable(safeConfig.identity.extraHeaders)
		end
		if type(safeConfig.providers) == "table" and type(safeConfig.providers.list) == "table" then
			for _, record in ipairs(safeConfig.providers.list) do
				if type(record) == "table" then
					-- Private labels and usage identities belong in explicit configuration transfers.
					record.keyNames, record.keyIds = nil, nil
					if type(record.params) == "table" and type(record.params.headers) == "table" then
						record.params.headers = redactHeaderTable(record.params.headers)
					end
				end
			end
		end
		return {
			format = M.format, version = M.version, createdAt = clock.ms(),
			info = env.info,
			place = placeSummary(),
			capabilities = caps and { summary = caps.summary(), executor = caps.executor, http = caps.http,
				requestName = caps.requestName, uaSupported = caps.uaSupported, studio = caps.studio,
				console = caps.console, available = caps.available } or { available = false },
			config = safeConfig,
			providers = providerList,
			permissions = permissions and { mode = permissions.mode(), rules = permissions.listRules() } or nil,
			tools = toolsSummary(),
			sessions = sessionsSummary(),
			http = httpSection,
			logs = logs,
			ui = uiSummary(),
			counts = { logs = #logs, http = httpSection and #(httpSection.items or {}) or 0 },
		}
	end

	function M.write(destination)
		local bundle = M.build()
		local encoded = util.encode(bundle)
		if #encoded > 2 * 1024 * 1024 then
			bundle.logs, bundle.http = {}, { available = false, truncated = true }
			encoded = util.encode(bundle)
		end
		if #encoded > 2 * 1024 * 1024 then return nil, "Support bundle exceeds the 2 MiB single-file limit even without logs." end
		local exports = env.require("runtime/native_exports")
		local path = destination or ("exports/uai-support-" .. tostring(clock.ms()) .. ".json")
		local result, why = exports.write(encoded, path)
		if not result then return nil, why end
		result.sections = { "place", "capabilities", "config", "providers", "permissions", "tools", "sessions", "http", "logs", "ui" }
		result.bytes = #encoded
		return result
	end

	return M
end
