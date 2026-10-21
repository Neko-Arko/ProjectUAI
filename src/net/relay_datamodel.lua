-- Loopback-only transport. Credentials and inference stay in POST bodies.
return function(env)
	local util = env.require("runtime/util")
	local guard = env.require("runtime/capture_guard")
	local host = game
	local M = {}
	function M.available()
		local ok, get, post = pcall(function() return host.HttpGet, host.HttpPost end)
		return ok and type(get) == "function" and type(post) == "function"
	end
	local function request(options)
		local base, port, path = tostring(options.Url or ""):match("^(http://127%.0%.0%.1:(%d+))(/api/.*)$")
		if not base or tonumber(port) < 1 or tonumber(port) > 65535 then error("invalid companion transport URL", 0) end
		local method, headers = options.Method, options.Headers or {}
		local auth = headers.Authorization
		if path == "/api/hello" and method == "GET" and not auth then
			return { StatusCode = 200, Body = host:HttpGet(options.Url, true), Headers = {} }
		end
		if path == "/api/pair" and method == "POST" and not auth then
			return { StatusCode = 200, Body = host:HttpPost(options.Url, options.Body or "{}", "application/json"), Headers = {} }
		end
		local id = path:match("^/api/inference/([%w_%-]+)$")
		local allowed = (method == "GET" and (path == "/api/hello" or path == "/api/status" or id))
			or (method == "POST" and path == "/api/inference") or (method == "DELETE" and id)
		if not allowed or (id and #id > 128) or type(auth) ~= "string" then error("invalid companion transport operation", 0) end
		local token = auth:match("^Bearer ([a-f0-9]+)$")
		if not token or #token ~= 64 then error("invalid companion transport credential", 0) end
		local encoded = util.encode({ schema = 1, method = method, path = path, token = token, body = options.Body or "" })
		local raw = host:HttpPost(base .. "/api/executor", encoded, "application/json")
		if type(raw) ~= "string" or #raw > 8 * 1024 * 1024 then error("response_limit: companion transport envelope", 0) end
		local reply = util.decode(raw)
		if type(reply) ~= "table" or reply.schema ~= 1 or type(reply.status) ~= "number"
			or reply.status % 1 ~= 0 or reply.status < 200 or reply.status > 599 or type(reply.body) ~= "string" then
			error("malformed: companion transport envelope", 0)
		end
		return { StatusCode = reply.status, Body = reply.body, Headers = {} }
	end
	function M.request(options)
		return guard.run(request, options)
	end
	return M
end
