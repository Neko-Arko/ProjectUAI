-- Discovery diagnostics and bounded exchanges in the offline executor harness.
-- This does not establish Android or mobile executor loopback support.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Companion discovery")
local case, check = suite.case, suite.check

local function fixture(options)
	options = options or {}
	local f = F.new({ executor = options.executor })
	f.calls, f.timeouts = {}, {}
	f.token, f.instance = ("a"):rep(64), "discovery-phone"
	f.config = f.env.require("runtime/config")
	if options.savedToken then f.config.set("relay.token", options.savedToken) end
	local caps = f.env.require("runtime/caps")
	if caps.fn.request then
		local request = caps.fn.request
		caps.fn.request = function(spec)
			f.timeouts[#f.timeouts + 1] = spec.Timeout
			return request(spec)
		end
	end
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
		error("discovery must not dispatch inference or other routes")
	end
	f.link = f.env.require("net/relay_link")
	function f.probe(seconds) return f.run(f.link.probe, seconds or 0.5) end
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
	{ label = "capacity", error = "capacity: native slots are busy", expected = "HTTP capacity is busy" },
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

suite.finish()
