-- Discovery diagnostics and bounded exchanges in the offline executor harness.
-- This does not establish Android or mobile executor loopback support.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Companion discovery")
local case, check = suite.case, suite.check

local function fixture(options)
	options = options or {}
	local f = F.new({ executor = options.executor })
	f.calls, f.timeouts, f.nativeCalls, f.submissions = {}, {}, {}, {}
	f.token, f.instance = ("a"):rep(64), "discovery-phone"
	local nativeRequest = f.h.sandbox.request
	function f.nativeAlias(name)
		return function(spec)
			f.nativeCalls[#f.nativeCalls + 1] = { name = name, spec = spec }
			f.timeouts[#f.timeouts + 1] = spec.Timeout
			if f.nativeOverride then
				local handled, response = f.nativeOverride(name, spec)
				if handled then return response end
			end
			return nativeRequest(spec)
		end
	end
	if nativeRequest then f.h.sandbox.request = f.nativeAlias("request") end
	if options.aliases then options.aliases(f) end
	f.config = f.env.require("runtime/config")
	if options.savedToken then f.config.set("relay.token", options.savedToken) end
	f.caps = f.env.require("runtime/caps")
	function f.reply(value, status, delay)
		return { StatusCode = status or 200, Body = type(value) == "string" and value or f.h.json.encode(value), delay = delay }
	end
	function f.hello()
		return { ok = true, server = "uai-relay", protocol = 2, instance = f.instance,
			capabilities = { inference = { schema = 1, unlimited = true } } }
	end
	f.h.http.relay = function(request)
		local step = request.url:match("/api/(.+)$")
		f.calls[#f.calls + 1] = step
		if f.override then
			local response = f.override(step, request)
			if response then return response end
		end
		if step == "hello" then return f.reply(f.hello(), 200, options.helloDelay) end
		if step == "status" then return f.reply(f.hello(), 200, options.statusDelay) end
		if step == "pair" then
			return f.reply({ ok = true, protocol = 2, instance = f.instance, token = f.token }, 200, options.pairDelay)
		end
		if step == "inference" and request.method == "POST" then
			local body = f.h.json.decode(request.body)
			f.submissions[#f.submissions + 1] = body
			return f.reply({ id = body.id, state = "running" }, 202)
		end
		local id = step:match("^inference/(.+)$")
		if id and request.method == "DELETE" then return f.reply({ cancelled = true }) end
		if id then return f.reply({ id = id, state = "completed", status = 200, headers = {}, body = "companion result" }) end
		error("unexpected companion route")
	end
	f.link = f.env.require("net/relay_link")
	function f.probe(seconds) return f.run(f.link.probe, seconds or 0.5) end
	function f.infer(options, seconds)
		local spec = { url = "https://provider.fixture/v1/chat/completions", method = "POST", body = "{}", relay = true, timeout = 20 }
		for key, value in pairs(options or {}) do spec[key] = value end
		return f.run(function() return f.env.require("net/http").send(spec) end, seconds or 3)
	end
	function f.bounded()
		check("native exchanges have a positive timeout", #f.timeouts > 0)
		for _, timeout in ipairs(f.timeouts) do check("each native exchange stays within five seconds", timeout >= 1 and timeout <= 5) end
	end
	function f.finish() f.healthy(); f.close() end
	return f
end

case("a hello and pairing taking more than two seconds each still connect", function()
	local f = fixture({ helloDelay = 2.2, pairDelay = 2.2 })
	local ok, reason = f.probe(5)
	check("the delayed companion becomes usable", ok and not reason and f.link.usable())
	check("one hello and one pairing are sufficient", #f.calls == 2 and f.calls[1] == "hello" and f.calls[2] == "pair")
	f.bounded(); f.finish()
end)

case("saved pairing checks can take more than two seconds", function()
	local f = fixture({ savedToken = ("a"):rep(64), statusDelay = 2.2 })
	check("saved pairing is verified", f.probe(3) and f.link.usable())
	check("valid saved pairing is not issued again", #f.calls == 2 and f.calls[2] == "status")
	f.bounded(); f.finish()
end)

case("a hello beyond five seconds reports its deadline and retains the native worker", function()
	local f = fixture({ helloDelay = 6.5 })
	local ok, reason = f.probe(5.5)
	check("deadline identifies the failing discovery step", not ok and reason:find("hello", 1, true) and reason:find("deadline", 1, true))
	check("diagnostic identifies the port and selected transport", reason:find("8790", 1, true) and reason:find("request", 1, true))
	check("failed discovery cannot pair or replay", #f.calls == 1 and not f.link.usable())
	check("unknown native outcome retains its slot", f.env.require("net/http").workers() == 1)
	f.h.sched.advance(2)
	check("late native completion releases only its slot", f.env.require("net/http").workers() == 0 and not f.link.usable())
	f.bounded(); f.finish()
end)

for _, item in ipairs({
	{ label = "timeout", error = "request timed out", expected = "deadline or timed out" },
	{ label = "timeout errno", error = "connect ETIMEDOUT", expected = "deadline or timed out" },
	{ label = "capacity", error = "capacity: native slots are busy", expected = "HTTP capacity is busy" },
	{ label = "abort", error = "aborted", expected = "was cancelled" },
	{ label = "native option", error = "unsupported option Timeout", expected = "native request option or argument" },
	{ label = "native argument", error = "invalid argument Timeout", expected = "native request option or argument" },
	{ label = "connection", error = "failed to connect", expected = "Connection refused or failed" },
	{ label = "cleartext", error = "Cleartext HTTP traffic not permitted", expected = "rejected local HTTP" },
	{ label = "HTTPS-only", error = "HTTPS-only requests are allowed", expected = "rejected local HTTP" },
	{ label = "unsupported protocol", error = "unsupported protocol", expected = "rejected local HTTP" },
	{ label = "permission", error = "permission denied", expected = "denied permission" },
	{ label = "empty response", error = "empty executor response", expected = "empty, malformed" },
	{ label = "unknown failure", error = "native call failed", expected = "unknown transport failure" },
}) do
	case(item.label .. " displays only a fixed safe category", function()
		local savedToken, unknownToken = ("c"):rep(64), ("e"):rep(64)
		local f = fixture({ savedToken = savedToken })
		f.override = function() error(item.error .. " " .. savedToken .. " " .. unknownToken .. " private-executor-body", 0) end
		local ok, reason = f.probe()
		check("transport category remains actionable", not ok and reason:find(item.expected, 1, true))
		check("known and unknown tokens are not exposed", not reason:find(savedToken, 1, true) and not reason:find(unknownToken, 1, true))
		check("arbitrary exception content never reaches the diagnostic", not reason:find("private-executor-body", 1, true) and #reason < 300)
		check("the status captures the same safe diagnostic", f.link.status().error == reason)
		if item.label == "timeout" or item.label == "timeout errno" or item.label == "capacity" or item.label == "abort" then
			check("terminal native failure never searches another profile", #f.nativeCalls == 1)
		end
		f.finish()
	end)
end

case("a pairing exception cannot expose an unsaved newly issued token or body", function()
	local f = fixture()
	local newToken = ("f"):rep(64)
	f.override = function(step)
		if step == "pair" then error('native call failed: {"issued":"' .. newToken .. '","body":"private-pair-body"}', 0) end
	end
	local ok, reason = f.probe()
	check("pairing exception identifies only its step and category", not ok and reason:find("pairing", 1, true) and reason:find("unknown transport failure", 1, true))
	check("new token and raw response are not displayed", not reason:find(newToken, 1, true) and not reason:find("private-pair-body", 1, true))
	check("failed pairing saves no token", f.config.get("relay.token", "") == "" and not f.link.usable())
	f.finish()
end)

for _, item in ipairs({
	{ label = "HTTP refusal", reply = "private HTTP body", status = 403, expected = "HTTP 403" },
	{ label = "invalid JSON", reply = "private invalid JSON body", expected = "invalid JSON" },
	{ label = "non-object JSON", reply = "true", expected = "JSON object" },
	{ label = "oversized reply", reply = ("private "):rep(600), expected = "oversized" },
}) do
	case(item.label .. " is distinguished without exposing the hello body", function()
		local f = fixture()
		f.override = function(step) if step == "hello" then return f.reply(item.reply, item.status) end end
		local ok, reason = f.probe()
		check("failure category is retained", not ok and reason:find(item.expected, 1, true))
		check("raw response does not reach the diagnostic", not reason:find("private", 1, true))
		check("invalid hello never pairs", #f.calls == 1 and f.config.get("relay.token", "") == "")
		f.finish()
	end)
end

for _, item in ipairs({
	{ field = "protocol", value = 1, expected = "incompatible protocol" },
	{ field = "instance", value = "", expected = "instance ID" },
	{ field = "server", value = "unrelated-server", expected = "another program" },
}) do
	case("hello " .. item.field .. " mismatch is explicit", function()
		local f = fixture()
		f.override = function(step)
			if step == "hello" then local info = f.hello(); info[item.field] = item.value; return f.reply(info) end
		end
		local ok, reason = f.probe()
		check("incompatible metadata has a specific diagnostic", not ok and reason:find(item.expected, 1, true))
		check("metadata rejection never pairs", #f.calls == 1 and not f.link.usable())
		f.finish()
	end)
end

case("only an explicit saved-token refusal repairs pairing", function()
	local f = fixture({ savedToken = ("b"):rep(64) })
	f.override = function(step) if step == "status" then return f.reply("private authentication body", 401) end end
	check("rejected saved token is repaired", f.probe() and f.config.get("relay.token") == f.token)
	check("repair follows hello and authenticated status", table.concat(f.calls, ",") == "hello,status,pair")
	f.finish()

	f = fixture({ savedToken = ("b"):rep(64) })
	f.override = function(step) if step == "status" then return f.reply("private server failure", 503) end end
	local ok, reason = f.probe()
	check("status failure remains distinct from token refusal", not ok and reason:find("saved-pairing check", 1, true) and reason:find("HTTP 503", 1, true))
	check("server failure cannot reset a token or pair again", table.concat(f.calls, ",") == "hello,status" and f.config.get("relay.token") == ("b"):rep(64))
	f.finish()
end)

case("pairing failure reports its step and never exposes a rejected token", function()
	local f = fixture()
	local rejectedToken = ("d"):rep(63)
	f.override = function(step)
		if step == "pair" then return f.reply({ ok = true, protocol = 2, instance = f.instance, token = rejectedToken }) end
	end
	local ok, reason = f.probe()
	check("invalid issued token is identified", not ok and reason:find("valid pairing token", 1, true))
	check("invalid token is never displayed or saved", not reason:find(rejectedToken, 1, true) and f.config.get("relay.token", "") == "")
	f.finish()
end)

case("settings cancellation cannot accept a delayed discovery reply", function()
	local f = fixture({ helloDelay = 2.2 })
	local ok, reason
	f.h.sched.spawn(function() ok, reason = f.link.probe() end)
	f.h.sched.advance(0.2)
	f.config.set("relay.mode", "off")
	f.h.sched.advance(3)
	check("cancelled probe cannot restore ready state", ok == false and reason == "cancelled" and f.link.status().state == "off")
	check("cancelled hello cannot start pairing", #f.calls == 1 and f.config.get("relay.token", "") == "")
	f.finish()
end)

case("plain HttpService is not mistaken for native phone loopback access", function()
	local f = fixture({ executor = false })
	local ok, reason = f.probe()
	check("missing native transport is explained", not ok and reason:find("executor HTTP", 1, true) and reason:find("HttpService", 1, true))
	check("no unusable loopback request is dispatched", #f.h.http.log == 0 and not f.link.usable())
	f.finish()
end)

local function strictTimeout(_, spec)
	if spec.Timeout ~= nil then error("unsupported option Timeout", 0) end
end

local function extraAlias(f)
	f.h.sandbox.syn = { request = f.nativeAlias("syn.request") }
end

case("a strict executor connects through minimal hello and retains it for authenticated inference", function()
	local f = fixture()
	f.nativeOverride = strictTimeout
	check("unsupported Timeout negotiates a verified connection", f.probe() and f.link.usable())
	check("only hello is compared before one pairing", #f.nativeCalls == 3 and table.concat(f.calls, ",") == "hello,pair")
	check("standard hello has no credentials", f.nativeCalls[1].spec.Headers.Authorization == nil)
	check("minimal hello omits optional Timeout and empty Headers", f.nativeCalls[2].spec.Timeout == nil and f.nativeCalls[2].spec.Headers == nil)
	check("pairing keeps required content headers", f.nativeCalls[3].spec.Headers["Content-Type"] == "application/json")
	check("the selected shape is visible", f.link.status().transport == "request minimal")
	local response = f.infer()
	check("authenticated inference completes exactly once", response and response.ok and response.body == "companion result" and #f.submissions == 1)
	for index = 4, #f.nativeCalls do
		local call = f.nativeCalls[index]
		check("every job exchange keeps the verified function, options and bearer", call.name == "request" and call.spec.Timeout == nil
			and call.spec.Headers.Authorization == "Bearer " .. f.token)
	end
	f.probe()
	local health = f.nativeCalls[#f.nativeCalls]
	check("verified health hello preserves client contact", health.spec.Url:find("/api/hello", 1, true) and health.spec.Headers.Authorization == "Bearer " .. f.token)
	f.finish()
end)

case("distinct captured aliases are deduplicated and selected only after validated pairing", function()
	local f = fixture({ savedToken = ("a"):rep(64), aliases = function(value)
		value.h.sandbox.http_request = value.h.sandbox.request
		value.h.sandbox.syn = { request = value.nativeAlias("syn.request") }
		value.h.sandbox.http = { request = value.h.sandbox.syn.request }
		value.h.sandbox.fluxus = { request = value.nativeAlias("fluxus.request") }
	end })
	local aliases = f.caps.requestAliases()
	check("duplicate function aliases are removed in preferred order", #aliases == 3 and aliases[1].name == "request"
		and aliases[2].name == "syn.request" and aliases[3].name == "fluxus.request")
	local primary = aliases[1].fn
	aliases[1].name, aliases[1].fn = "untrusted name", function() error("mutated inventory") end
	f.h.sandbox.request = function() error("late global replacement") end
	check("the captured inventory is not mutated by its callers", f.caps.requestAliases()[1].fn == primary and f.caps.requestAliases()[1].name == "request")
	f.nativeOverride = function(name, spec)
		if name == "request" then error("native call failed", 0) end
		if name == "syn.request" then assert(spec.Timeout == nil, "alternate alias must use minimal options") end
	end
	f.override = function(step)
		if step == "status" then check("hello alone never publishes a profile", not f.link.usable() and f.link.endpoint() == nil and f.link.status().transport == nil) end
	end
	check("working alias authenticates the saved token", f.probe() and f.link.status().transport == "syn.request minimal")
	check("alias attempts are bounded without duplicate functions", #f.nativeCalls == 4 and f.nativeCalls[1].name == "request"
		and f.nativeCalls[2].name == "request" and f.nativeCalls[3].name == "syn.request" and f.nativeCalls[4].name == "syn.request")
	for index = 1, 3 do
		local spec = f.nativeCalls[index].spec
		check("compatibility hello never carries a saved credential", spec.Method == "GET" and spec.Url:find("/api/hello", 1, true)
			and (spec.Headers == nil or spec.Headers.Authorization == nil) and spec.Body == nil)
	end
	check("only authenticated status follows validation", f.nativeCalls[4].spec.Url:find("/api/status", 1, true)
		and f.nativeCalls[4].spec.Headers.Authorization == "Bearer " .. f.token and f.caps.fn.request == primary)
	f.finish()
end)

case("exhausted compatibility reports all fixed aliases and shapes without raw error content", function()
	local f = fixture({ aliases = function(value)
		value.h.sandbox.http_request = value.nativeAlias("http_request")
		value.h.sandbox.syn = { request = value.nativeAlias("syn.request") }
		value.h.sandbox.http = { request = value.nativeAlias("http.request") }
		value.h.sandbox.fluxus = { request = value.nativeAlias("fluxus.request") }
	end })
	f.nativeOverride = function() error("unknown private-native-body " .. f.token, 0) end
	local ok, reason = f.probe(1)
	check("five captured functions allow at most six hello shapes", not ok and #f.nativeCalls == 6 and #f.calls == 0)
	check("diagnostic identifies the completed throw origin", reason:find("executor threw", 1, true))
	check("diagnostic preserves the fixed attempt list", reason:find("request standard, request minimal, http_request minimal, syn.request minimal, http.request minimal, fluxus.request minimal", 1, true))
	check("exhausted errors do not disclose arbitrary text", not reason:find("private-native-body", 1, true) and not reason:find(f.token, 1, true) and #reason < 500)
	f.finish()
end)

for _, item in ipairs({
	{ label = "bodyless native status", response = { StatusCode = 0, StatusMessage = "private unknown status" } },
	{ label = "non-table native return", response = false },
	{ label = "malformed native body", response = { StatusCode = 200, Body = {} } },
	{ label = "response normalization exception", response = setmetatable({}, { __index = function() error("private normalization error", 0) end }) },
}) do
	case(item.label .. " stops compatibility without disclosing the returned data", function()
		local f = fixture({ aliases = extraAlias })
		f.nativeOverride = function() return true, item.response end
		local ok, reason = f.probe()
		check("a returned response never authorizes another alias", not ok and #f.nativeCalls == 1 and not f.link.usable())
		check("the fixed failure origin distinguishes response handling", reason:find("executor returned an unusable response", 1, true)
			and not reason:find("private", 1, true))
		f.finish()
	end)
end

for _, item in ipairs({
	{ field = "server", value = "other-program" }, { field = "protocol", value = 1 }, { field = "instance", value = "" },
	{ status = 403 },
}) do
	case("a rejected minimal hello cannot try another alias or disclose the saved token: " .. tostring(item.field or "HTTP"), function()
		local f = fixture({ savedToken = ("b"):rep(64), aliases = extraAlias })
		f.nativeOverride = strictTimeout
		f.override = function(step)
			if step == "hello" then
				local info = f.hello()
				if item.field then info[item.field] = item.value end
				return f.reply(info, item.status)
			end
		end
		check("invalid metadata and HTTP refusal stop after the minimal hello", not f.probe() and #f.nativeCalls == 2 and #f.calls == 1)
		check("failed validation cannot select a transport or authenticate", f.link.status().transport == nil and f.link.endpoint() == nil
			and f.nativeCalls[2].spec.Headers == nil and f.config.get("relay.token") == ("b"):rep(64))
		f.finish()
	end)
end

case("a minimal hello timeout retains one worker and never tries a further alias", function()
	local f = fixture({ helloDelay = 6.5, aliases = extraAlias })
	f.nativeOverride = strictTimeout
	local ok, reason = f.probe(5.5)
	check("the timed-out candidate is terminal for discovery", not ok and reason:find("deadline", 1, true) and #f.nativeCalls == 2)
	check("the unbounded native option still retains bounded caller ownership", f.env.require("net/http").workers() == 1 and not f.link.usable())
	f.h.sched.advance(2)
	check("late native completion does not authorize pairing or an alias", f.env.require("net/http").workers() == 0 and #f.nativeCalls == 2 and not f.link.usable())
	f.finish()
end)

case("stale minimal hello cannot select an alias or pair", function()
	local f = fixture({ helloDelay = 2.2, aliases = extraAlias })
	f.nativeOverride = strictTimeout
	local ok, reason
	f.h.sched.spawn(function() ok, reason = f.link.probe() end)
	f.h.sched.advance(0.3)
	f.config.set("relay.mode", "off")
	f.h.sched.advance(3)
	check("stale profile search is abandoned", ok == false and reason == "cancelled" and #f.nativeCalls == 2)
	check("no late credential or selected transport survives", f.config.get("relay.token", "") == "" and f.link.status().transport == nil and not f.link.usable())
	f.finish()
end)

for _, step in ipairs({ "status", "pair" }) do
	case("failed " .. step .. " on a compatible profile cannot try another transport", function()
		local f = fixture({ savedToken = step == "status" and ("b"):rep(64) or nil, aliases = extraAlias })
		f.nativeOverride = strictTimeout
		f.override = function(current) if current == step then error("unknown private-auth-failure", 0) end end
		local ok, reason = f.probe()
		check("authentication is attempted once without fallback", not ok and #f.nativeCalls == 3 and #f.calls == 2)
		check("hello compatibility is not committed after authentication failure", f.link.status().transport == nil and not f.link.usable())
		check("authentication exceptions remain fixed and private", reason:find("executor threw", 1, true) and not reason:find("private-auth-failure", 1, true))
		f.finish()
	end)
end

case("lost inference receipts retain one ID and never negotiate another native profile", function()
	local f = fixture({ aliases = extraAlias })
	f.nativeOverride = strictTimeout
	check("strict primary profile pairs", f.probe())
	local ids = {}
	f.override = function(step, request)
		if step == "inference" then
			local input = f.h.json.decode(request.body)
			ids[#ids + 1] = input.id
			if #ids < 3 then error("lost native receipt", 0) end
		end
	end
	local response = f.infer(nil, 5)
	check("receipt recovery uses one inference identity", response and response.ok and #ids == 3 and ids[1] == ids[2] and ids[2] == ids[3])
	for _, call in ipairs(f.nativeCalls) do check("inference errors do not select another executor alias", call.name == "request") end
	f.finish()
end)

case("an accepted job pins its copied profile through rediscovery, polls and cancellation", function()
	local f = fixture({ aliases = extraAlias })
	f.nativeOverride = function(name, spec)
		if name == "request" and f.switch and spec.Url:find("/api/hello", 1, true) then error("primary hello unavailable", 0) end
		return strictTimeout(name, spec)
	end
	check("job starts with the primary minimal profile", f.probe())
	local endpoint = f.link.endpoint()
	local cancelled, rediscovered, posts, polls, deletes = false, false, 0, 0, 0
	f.override = function(step, request)
		if step == "inference" then
			posts = posts + 1
			endpoint.executorProfile.request = function() error("mutated endpoint must not be used", 0) end
			endpoint.executorProfile.useTimeout = true
			f.switch = true
			f.h.sched.spawn(function() rediscovered = f.link.probe() end)
		elseif step:find("inference/", 1, true) then
			if request.method == "DELETE" then deletes = deletes + 1
			else
				polls = polls + 1
				return f.reply({ id = step:match("inference/(.+)$"), state = "running" })
			end
		end
	end
	f.h.sched.delay(2.5, function() cancelled = true end)
	local response, reason = f.infer({ relayEndpoint = endpoint, aborted = function() return cancelled end }, 4)
	check("subsequent discovery verifies another alias", rediscovered and f.link.status().transport == "syn.request minimal")
	check("the accepted job cancels without a replacement submission", response == nil and reason == "aborted" and posts == 1 and polls > 0 and deletes == 1)
	for _, call in ipairs(f.nativeCalls) do
		if call.spec.Url:find("/api/inference", 1, true) then
			check("all accepted-job POST, poll and DELETE calls retain the original copied profile", call.name == "request" and call.spec.Timeout == nil
				and call.spec.Headers.Authorization == "Bearer " .. f.token)
		end
	end
	f.finish()
end)

local function dataModelFixture(old)
	local f = fixture()
	f.nativeOverride = function() error("HttpError: ConnectFail", 0) end
	f.posts, f.gets = {}, {}
	f.h.sandbox.game.HttpGet = function(_, url)
		f.gets[#f.gets + 1] = url
		local info = f.hello()
		if not old then info.capabilities.executorPost = { schema = 1 } end
		return f.h.json.encode(info)
	end
	f.h.sandbox.game.HttpPost = function(_, url, body, contentType)
		check("HttpPost keeps JSON and credentials out of URLs", contentType == "application/json" and not url:find(f.token, 1, true)
			and not url:find("?", 1, true))
		f.posts[#f.posts + 1] = { url = url, body = body }
		if f.postOverride then local answer = f.postOverride(url, body); if answer then return answer end end
		if url:find("/api/pair", 1, true) then
			return f.reply({ ok = true, protocol = 2, instance = f.instance, token = f.token }).Body
		end
		local input = f.h.json.decode(body)
		check("authenticated POST envelope retains token and schema", input.token == f.token and input.schema == 1)
		local response = f.h.http.relay({ url = "http://127.0.0.1:8790" .. input.path, method = input.method, body = input.body })
		return f.h.json.encode({ schema = 1, status = response.StatusCode, body = response.Body })
	end
	return f
end

case("Delta ConnectFail can pair and infer through the advertised DataModel transport", function()
	local f = dataModelFixture()
	check("fallback authenticates before becoming usable", f.probe() and f.link.status().transport == "HttpGet/HttpPost minimal")
	local response = f.infer()
	check("one provider job returns through POST polling", response and response.body == "companion result" and #f.submissions == 1)
	check("GET was only used for public discovery", #f.gets == 1 and f.gets[1] == "http://127.0.0.1:8790/api/hello")
	f.finish()
end)

case("an old companion reached via HttpGet requires an update without pairing", function()
	local f = dataModelFixture(true)
	local ok, reason = f.probe()
	check("old app reports the exact required update", not ok and reason:find("Install UAI Relay 3.5.7", 1, true) and #f.posts == 0)
	f.finish()
end)

case("DataModel timeout retains native ownership and cannot select the profile", function()
	local f = dataModelFixture()
	f.postOverride = function() f.h.sched.wait(7); return "{}" end
	local ok = f.probe(5.5)
	check("pair wait is bounded with one POST", not ok and not f.link.usable() and #f.posts == 1 and f.env.require("net/http").workers() == 1)
	f.h.sched.advance(2)
	check("late pair cannot connect", not f.link.usable() and f.env.require("net/http").workers() == 0)
	f.finish()
end)

case("DataModel cancellation preserves the original accepted job", function()
	local f = dataModelFixture()
	check("DataModel connects", f.probe())
	local stopped, deleted = false, 0
	f.override = function(step, request)
		local id = step:match("^inference/(.+)$")
		if id and request.method == "DELETE" then deleted = deleted + 1
		elseif id then return f.reply({ id = id, state = "running" }) end
	end
	f.h.sched.delay(2, function() stopped = true end)
	local response, reason = f.infer({ aborted = function() return stopped end }, 3)
	check("Stop sends one cancellation without new inference", not response and reason == "aborted" and deleted == 1 and #f.submissions == 1)
	f.finish()
end)

suite.finish()
