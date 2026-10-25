-- AgentRouter protocol choices stay on its documented routes and model IDs.
return function(env)
	local util = env.require("runtime/util")
	local urls = env.require("net/url")
	local config = env.require("runtime/config")
	local M = {}
	local HOSTS = { ["agentrouter.org"] = true, ["api.agentrouter.org"] = true, ["ps.air-outer.com"] = true }

	function M.matches(record)
		local parsed = urls.parse(urls.normaliseBase(record and record.baseUrl or ""))
		if not parsed or parsed.scheme ~= "https" then return false end
		local authority = parsed.authority:lower()
		if authority ~= parsed.host and authority ~= parsed.host .. ":443" then return false end
		local path = parsed.path:gsub("/+$", "")
		path = path:match("^(.*)/chat/completions$") or path:match("^(.*)/messages$")
			or path:match("^(.*)/responses$") or path:match("^(.*)/models$") or path
		return (HOSTS[parsed.host] and path == "/v1") == true
			or (parsed.host == "puai-proxy.davidzk.tech" and path == "/agentrouter/v1")
	end

	function M.protocol(record)
		if not M.matches(record) then return nil end
		local parsed = urls.parse(urls.normaliseBase(record.baseUrl))
		if parsed.path:gsub("/+$", ""):match("/responses$") or util.trim(record.model):lower():match("^gpt%-") then return "responses" end
	end

	function M.responsesDefaults(record, request, body)
		if not M.matches(record) then return end
		-- Full UAI history is supplied on every request. Avoid server-stored
		-- response references that may belong to another gateway resource.
		body.store = false
		local wanted = request.effort or config.get("agent.effort", "low")
		local level = env.require("provider/traits").nearestEffort(record.model, wanted)
		if not level and ({ low = true, medium = true, high = true, xhigh = true, max = true })[wanted] then level = wanted end
		if level then body.reasoning = { effort = level } end
		if body.tools then body.parallel_tool_calls = request.parallelToolCalls ~= false end
	end

	function M.toolDefaults(record, body)
		if not M.matches(record) then return end
		if type(body.tools) == "table" then
			local tools = {}
			for index, original in ipairs(body.tools) do
				local tool = util.copy(original); tools[index] = tool
				-- Responses otherwise normalizes optional schema properties into
				-- required ones, which changes the meaning of UAI tool arguments.
				if tool.type == "function" and tool.strict == nil then tool.strict = false end
			end
			body.tools = tools
		end
	end

	return M
end
