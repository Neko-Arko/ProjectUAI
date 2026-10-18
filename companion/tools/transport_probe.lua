-- Run separately in Delta's editor with the companion started on port 8790.
-- GET-only diagnostics: no pairing, provider calls, credentials or response dumps.
local PREFIX = "[uai-transport] "
local json = game:GetService("HttpService")
local function clean(value)
	if type(value) ~= "string" then return "<" .. type(value) .. " error>" end
	-- Keep a short native error, never structured dumps, URLs or long identifiers.
	local text = value:sub(1, 2048):match("^[^\r\n]*") or ""
	text = text:gsub("[{<].*", "[details omitted]")
	text = text:gsub("https?://[^%s]+", "[url]")
	text = text:gsub("[%w._%%+%-]+@[%w.%-]+", "[address]")
	text = text:gsub("[Bb][Ee][Aa][Rr][Ee][Rr]%s+[^%s,;]+", "Bearer [redacted]")
	text = text:gsub("([%w_%-]+)(%s*[:=]%s*)([^%s,;]+)", function(key, separator, item)
		local name = key:lower():gsub("[_%-]", "")
		if name:find("key", 1, true) or name:find("token", 1, true) or name:find("secret", 1, true)
			or name:find("password", 1, true) or name:find("cookie", 1, true)
			or name:find("authorization", 1, true) or name:find("fingerprint", 1, true)
			or name:find("identifier", 1, true) then return key .. separator .. "[redacted]" end
		return key .. separator .. item
	end)
	text = text:gsub("[%w_%-]+", function(word) return #word >= 24 and "[redacted]" or word end)
	return (text:gsub("[%c]", " "):sub(1, 240))
end

local candidates = {
	{ "request", request }, { "http_request", http_request },
	{ "syn.request", type(syn) == "table" and syn.request },
	{ "http.request", type(http) == "table" and http.request },
	{ "fluxus.request", type(fluxus) == "table" and fluxus.request },
}
local native, nativeName
for _, candidate in ipairs(candidates) do
	if type(candidate[2]) == "function" then nativeName, native = candidate[1], candidate[2]; break end
end

local function measure(label, fn, expectsHello, bodyOnly)
	print(PREFIX .. "START " .. label)
	local started, done, accepting = tick(), false, true
	local succeeded, result
	task.spawn(function()
		if not accepting then return end
		local ok, value = pcall(fn)
		if accepting then succeeded, result, done = ok, value, true end
	end)
	while not done and tick() - started < 5 do task.wait(0.05) end
	accepting = false
	local elapsed = tick() - started
	if not done or elapsed > 5 then
		print(PREFIX .. label .. " WAIT EXPIRED; native outcome unknown. Probe stopped; no further calls.")
		return false
	end
	local timing = (" %.2fs"):format(elapsed)
	if not succeeded then
		print(PREFIX .. label .. " THREW" .. timing .. ": " .. clean(result))
		return true
	end
	local ok, summary = pcall(function()
		local body, status
		if bodyOnly then body = result
		elseif type(result) == "table" then
			body, status = result.Body or result.ResponseData, tonumber(result.StatusCode or result.Status)
		else return "RETURNED " .. type(result) end
		local details = bodyOnly and "BODY" or ("HTTP " .. tostring(status or 0))
		if type(body) ~= "string" then return details .. " body=" .. type(body) end
		details = details .. " bytes=" .. tostring(#body)
		if expectsHello then
			local decoded, info = false, nil
			if #body <= 4096 then decoded, info = pcall(json.JSONDecode, json, body) end
			local valid = decoded and type(info) == "table" and info.server == "uai-relay" and info.protocol == 2
				and type(info.instance) == "string" and #info.instance > 0 and #info.instance <= 128
			details = details .. (valid and " companion-hello=valid" or " companion-hello=invalid")
		end
		return details
	end)
	print(PREFIX .. label .. timing .. " " .. (ok and summary or "UNUSABLE RESPONSE"))
	return true
end

print(PREFIX .. "v1; port 8790; GET only; native errors scrubbed; bodies omitted")
if type(identifyexecutor) == "function" then
	local ok, name, version = pcall(identifyexecutor)
	if ok then print(PREFIX .. "executor=" .. clean(name) .. " version=" .. clean(version or "unknown")) end
end
if native then
	print(PREFIX .. "native=" .. nativeName)
	for _, host in ipairs({ "127.0.0.1", "localhost" }) do
		local url = "http://" .. host .. ":8790/api/hello"
		if not measure(nativeName .. " " .. host, function()
			return native({ Url = url, Method = "GET" })
		end, true, false) then return end
	end
else print(PREFIX .. "native request unavailable") end

for _, host in ipairs({ "127.0.0.1", "localhost" }) do
	local url = "http://" .. host .. ":8790/api/hello"
	if not measure("HttpGet " .. host, function() return game:HttpGet(url, true) end, true, true) then return end
end
if native and not measure(nativeName .. " public HTTPS", function()
	return native({ Url = "https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/companion/tools/README.md", Method = "GET" })
end, false, false) then return end
print(PREFIX .. "DONE; hello access alone does not prove pairing or inference support.")
