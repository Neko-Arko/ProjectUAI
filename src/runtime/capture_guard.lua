-- Marks work this client owns, so a capture never records its own traffic.
--
-- The marker is per coroutine. A global counter would mark every thread while a
-- yielded UAI request is in flight, and a loader running on another thread would
-- be dropped by the capture wrapper for no reason.
return function(env)
	local M = {}
	local MAIN = {}
	local depth = setmetatable({}, { __mode = "k" })
	local unpackValues = table.unpack or unpack

	local function pack(...)
		return { n = select("#", ...), ... }
	end

	local function current()
		local thread = coroutine.running()
		return thread or MAIN
	end

	function M.enter()
		local thread = current()
		depth[thread] = (depth[thread] or 0) + 1
	end

	function M.leave()
		local thread = current()
		local count = depth[thread]
		if not count then return end
		if count <= 1 then depth[thread] = nil else depth[thread] = count - 1 end
	end

	function M.active()
		return (depth[current()] or 0) > 0
	end

	-- Call a host function with this coroutine marked as client-owned. Errors are
	-- re-raised unchanged so a caller's pcall sees what it always did.
	function M.run(fn, ...)
		M.enter()
		local result = pack(pcall(fn, ...))
		M.leave()
		if not result[1] then error(result[2], 0) end
		return unpackValues(result, 2, result.n)
	end

	return M
end
