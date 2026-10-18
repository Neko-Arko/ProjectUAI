-- Run on its own in the mobile executor. This checks discovery and pairing only;
-- use relay_probe.lua to measure a long request through the companion.
-- Tokens and raw response bodies are never printed.
local PORT = 8790
local fn = request or http_request
	or (type(syn) == "table" and syn.request)
	or (type(http) == "table" and http.request)
	or (type(fluxus) == "table" and fluxus.request)
if type(fn) ~= "function" then print("[probe] FAIL: no executor request function") return end
local json = game:GetService("HttpService")
local base = "http://127.0.0.1:" .. PORT

local function call(path, method, headers, body)
	local started = tick()
	local ok, response = pcall(fn, { Url = base .. path, Method = method,
		Headers = headers or {}, Body = body, Timeout = 5 })
	local status = ok and type(response) == "table" and tonumber(response.StatusCode or response.Status) or 0
	local text = type(response) == "table" and (response.Body or response.ResponseData) or nil
	local decoded
	if type(text) == "string" and #text <= 65536 then
		local parsed, value = pcall(json.JSONDecode, json, text)
		if parsed and type(value) == "table" then decoded = value end
	end
	print(("[probe] %s status=%s elapsed=%.2fs"):format(path, tostring(status), tick() - started))
	return status, decoded
end

local status, hello = call("/api/hello", "GET")
if status ~= 200 or not hello or hello.server ~= "uai-relay" or hello.protocol ~= 2 or type(hello.instance) ~= "string" then
	print("[probe] FAIL: no compatible companion answered. Check Start, port, and this executor's loopback support.") return
end
local pairStatus, pair = call("/api/pair", "POST", { ["Content-Type"] = "application/json" },
	'{"client":"ProjectUAI-Probe","version":"1.1.0","protocol":2,"placeId":0,"gameId":0}')
if pairStatus ~= 200 or not pair or pair.ok ~= true or pair.protocol ~= 2 or pair.instance ~= hello.instance
	or type(pair.token) ~= "string" or #pair.token ~= 64 or not pair.token:match("^[a-f0-9]+$") then
	print("[probe] FAIL: companion pairing was not confirmed") return
end
local authStatus, info = call("/api/status", "GET", { Authorization = "Bearer " .. pair.token })
if authStatus ~= 200 or not info or info.server ~= "uai-relay" or info.protocol ~= 2 or info.instance ~= hello.instance then
	print("[probe] FAIL: authenticated companion contact was not confirmed") return
end
print("[probe] PASS: loopback discovery, pairing and authenticated contact. Inference has not been tested.")
