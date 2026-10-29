-- Offline provisioning for the public free provider. The provider-supported
-- `auto` router was verified against live /models and a successful tool call.
-- Startup does not discover models or dispatch inference on the user's behalf.
return function(env)
	local config = env.require("runtime/config")
	local registry = env.require("provider/registry")
	local communityKey = env.require("provider/community_key")
	local dispose = env.require("runtime/dispose")
	local M = {}
	local unsubscribe

	function M.use()
		local access = config.accessProblem()
		if access then return nil, access end
		local vault = config.vaultStatus()
		if vault.locked or vault.busy then return nil, "Unlock the credential vault before changing providers." end
		for _, record in ipairs(registry.list()) do
			if communityKey.isApplied(record) then
				record.enabled = true
				if not record.model or record.model == "" then registry.setModel(record.id, "auto") end
				registry.setActive(record.id)
				return record
			end
		end
		local record = registry.blank("hcnsec")
		local saved, problems = registry.save(record)
		if not saved then return nil, table.concat(problems or {}, "; ") end
		local selected, problem = registry.setActive(record.id)
		if not selected then return nil, problem end
		return record
	end

	function M.ensure()
		local access = config.accessProblem()
		if access then return registry.active(), access end
		if config.vaultStatus().locked then return registry.active() end
		local list = registry.list()
		if #list == 0 then return M.use() end
		local selected = config.get("providers.active", "")
		if not registry.get(selected) then
			for _, record in ipairs(list) do
				if record.enabled ~= false then registry.setActive(record.id); return record end
			end
		end
		return registry.active()
	end

	function M.start()
		if unsubscribe then return end
		M.ensure()
		unsubscribe = config.changed:connect(function(path)
			-- Import and reset restore the default when they leave no providers.
			-- Explicit removal stays removed for this session; the Free action can
			-- add it again, and the next boot provisions an otherwise empty setup.
			if path == nil or path == "providers" then M.ensure() end
		end)
	end

	function M.stop()
		if unsubscribe then unsubscribe(); unsubscribe = nil end
	end

	dispose.add(M.stop, "free provider configuration")
	return M
end
