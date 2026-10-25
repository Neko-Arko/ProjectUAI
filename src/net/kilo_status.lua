-- Normalizes optional helper capabilities from either local transport.
return function(env)
	local util = env.require("runtime/util")
	local M = {}
	local states = { standby = true, disabled = true, starting = true, downloading = true,
		ready = true, rotating = true, limited = true, failed = true }
	function M.read(value)
		if type(value) ~= "table" or value.schema ~= 1 then return nil end
		local state = states[value.state] and value.state or "unavailable"
		return { enabled = value.enabled == true,
			available = value.available == true and (state == "ready" or state == "rotating"),
			state = state, message = util.truncate(tostring(value.message or ""), 400) }
	end
	return M
end
