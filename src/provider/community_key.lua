-- The intentionally distributed Project UAI Free credential. Importing this
-- module sends no traffic. Never replace it with a private development key.
return function(env)
	local url = env.require("net/url")
	local M = {}
	local key = "sk-ysUaToxuHpUyGBsqxcbBne8x7u4Qr7L6wAclRAG2VuhM1luY"
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
	function M.isApplied(record)
		if not M.eligible(record) or record.apiKey ~= key or (record.authStyle or "bearer") ~= "bearer" then return false end
		-- Extra headers win over generated authentication. A personal override
		-- must not keep the included-access badge or its zero-cost estimate.
		for name, value in pairs(record.headers or {}) do
			local lower = type(name) == "string" and name:lower() or ""
			if lower == "authorization" and tostring(value) ~= "Bearer " .. key then return false end
			if (lower == "x-api-key" or lower == "api-key") and tostring(value) ~= key then return false end
		end
		return true
	end
	return M
end
