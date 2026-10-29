-- The intentionally distributed Project UAI Free credential. Importing this
-- module sends no traffic. Never replace it with a private development key.
return function(env)
	local url = env.require("net/url")
	local util = env.require("runtime/util")
	local M = {}
	local credential = env.require("runtime/community_credential")
	local key = credential.key
	function M.eligible(record)
		if type(record) ~= "table" or record.preset ~= "hcnsec" then return false end
		local base = url.normaliseBase(record.baseUrl)
		local parsed = url.parse(base)
		return parsed ~= nil and parsed.scheme == "https" and parsed.authority:lower() == "api.hcnsec.cn"
			and parsed.path == "/v1" and (not parsed.query or parsed.query == "")
	end
	function M.apply(record)
		if not M.eligible(record) then return nil, "Project UAI Free requires the official HCNSEC endpoint. Help: https://discord.gg/9xYyyYuKap" end
		record.apiKey = key
		record.authStyle = "bearer"
		record.keyRotation = nil
		record.keyNames, record.keyMode, record.selectedKey, record.keyPaused = nil, "rotate", 1, nil
		record.keyIds = nil
		for name, value in pairs(record.headers or {}) do
			local lower = type(name) == "string" and name:lower() or ""
			if (lower == "authorization" and tostring(value) ~= "Bearer " .. key)
				or ((lower == "x-api-key" or lower == "api-key") and tostring(value) ~= key) then
				record.headers[name] = nil
			end
		end
		return true
	end
	local function usesIncluded(record, expected)
		if not M.eligible(record) or record.apiKey ~= expected or (record.authStyle or "bearer") ~= "bearer" then return false end
		-- Extra headers win over generated authentication. A personal override
		-- must not keep the included-access badge or its zero-cost estimate.
		for name, value in pairs(record.headers or {}) do
			local lower = type(name) == "string" and name:lower() or ""
			if lower == "authorization" and tostring(value) ~= "Bearer " .. expected then return false end
			if (lower == "x-api-key" or lower == "api-key") and tostring(value) ~= expected then return false end
		end
		return true
	end
	function M.isApplied(record)
		return usesIncluded(record, key)
	end
	function M.migrate(record)
		if not M.eligible(record) or not credential.isRetired(record.apiKey) then return false end
		-- Replace only the exact old included credential and matching auth copies.
		-- Preserve personal header overrides and key preferences; usage IDs cannot
		-- follow a different credential into its new accounting history.
		local previous = record.apiKey
		record.apiKey, record.keyIds, record.keyRotation = key, nil, nil
		for name, value in pairs(record.headers or {}) do
			local lower = type(name) == "string" and name:lower() or ""
			if lower == "authorization" and value == "Bearer " .. previous then record.headers[name] = "Bearer " .. key
			elseif (lower == "x-api-key" or lower == "api-key") and value == previous then record.headers[name] = key end
		end
		return true
	end
	function M.restore(record)
		if not M.eligible(record) or record.communityCredential ~= true or util.trim(record.apiKey) ~= "" then return false end
		local state = record.communityKeyState
		if state ~= nil then
			if type(state) ~= "table" or type(state.revision) ~= "string" or state.revision == "" then return false end
			local metadata = { apiKey = key }
			local fields = { "keyNames", "keyIds", "keyPaused", "keyMode", "selectedKey" }
			for _, field in ipairs(fields) do metadata[field] = util.deepCopy(state[field]) end
			if not env.require("runtime/provider_keys").validate(metadata) then return false end
			for _, field in ipairs(fields) do record[field] = metadata[field] end
			if state.revision ~= credential.revision then record.keyIds, record.keyRotation = nil, nil end
			record.communityKeyState = nil
		end
		-- Restore only the included key and its known metadata. Connection fields
		-- and explicit personal auth overrides retain their existing values.
		record.apiKey = key
		return true
	end

	M.hours = "20:00-06:00 UTC+8 (Beijing/Singapore)"
	-- This is local request guidance, not upstream access control. Fixed UTC+8
	-- avoids the host's local timezone and daylight-saving settings entirely.
	function M.availability(record, atMs)
		if not M.isApplied(record) then return { applies = false, open = true } end
		local now = atMs or env.require("runtime/clock").ms()
		if type(now) ~= "number" or now ~= now or math.abs(now) == math.huge then
			return { applies = true, open = false, hours = M.hours,
				message = "Project UAI Free cannot determine its scheduled hours. Check your device clock. Available daily " .. M.hours .. "." }
		end
		local hour, day = 3600000, 86400000
		local shifted = now + 8 * hour
		local sinceMidnight = shifted % day
		local midnight = now - sinceMidnight
		local open = sinceMidnight < 6 * hour or sinceMidnight >= 20 * hour
		local nextOpen = midnight + 20 * hour
		if sinceMidnight >= 20 * hour then nextOpen = nextOpen + day end
		local nextClose = midnight + 6 * hour
		if sinceMidnight >= 6 * hour then nextClose = nextClose + day end
		return { applies = true, open = open, hours = M.hours, nextOpenMs = nextOpen, nextCloseMs = nextClose,
			message = open and ("Project UAI Free is within its daily " .. M.hours .. " schedule. Shared capacity and speed can vary.")
				or ("Project UAI Free is outside its daily " .. M.hours .. " schedule. Try again from 20:00 UTC+8 or choose another provider.") }
	end

	function M.problem(record, atMs)
		local status = M.availability(record, atMs)
		if not status.open then return status.message end
	end
	return M
end
