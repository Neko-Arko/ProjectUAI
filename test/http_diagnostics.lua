-- Transport outcomes must agree with their retained request diagnostics.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("HTTP diagnostics")
local case, check = suite.case, suite.check

case("successful responses have no invented transport error", function()
	local f = F.new()
	local http, caps = f.env.require("net/http"), f.env.require("runtime/caps")
	for _, status in ipairs({ 200, 204 }) do
		caps.fn.request = function()
			return { StatusCode = status, Body = status == 200 and '{"reply":"done"}' or "", Headers = { server = "fixture", ["cf-ray"] = "trace-id" } }
		end
		local response, why = http.request({ url = "https://fixture.test/chat", method = "POST", body = "{}", identity = "none" })
		local entry = http.history[#http.history]
		check("HTTP " .. status .. " succeeds without an error", response and response.ok and why == nil and entry.error == nil)
		check("HTTP " .. status .. " retains its actual evidence", entry.status == status and entry.server == "fixture" and entry.trace == "trace-id" and entry.via == "executor")
	end
	f.healthy(); f.close()
end)

case("HTTP refusal remains distinct from transport failure", function()
	local f = F.new()
	local http, caps = f.env.require("net/http"), f.env.require("runtime/caps")
	caps.fn.request = function() return { StatusCode = 403, Body = "Denied", Headers = { server = "fixture" } } end
	local response = http.request({ url = "https://fixture.test/denied", identity = "none" })
	check("a received refusal has an HTTP outcome and no transport error", response and not response.ok and response.status == 403 and response.entry.error == nil)
	caps.fn.request = function() error("fixture network unavailable") end
	local absent, why = http.request({ url = "https://fixture.test/unavailable", identity = "none" })
	local entry = http.history[#http.history]
	check("real transport failures keep their reason", not absent and tostring(why):find("fixture network unavailable", 1, true) and entry.error == why and entry.status == 0)
	caps.fn.request = function() return { StatusCode = 200, Body = {} } end
	absent, why = http.request({ url = "https://fixture.test/malformed", identity = "none" })
	check("invalid response bodies still report a transport error", not absent and tostring(why):find("malformed:", 1, true) and http.history[#http.history].error == why)
	f.healthy(); f.close()
end)

case("short native probes retain positive integer timeouts after worker setup", function()
	for _, budget in ipairs({ 1, 2.25, 5 }) do
		local f = F.new()
		local http, caps, clock = f.env.require("net/http"), f.env.require("runtime/caps"), f.env.require("runtime/clock")
		-- Native worker setup costs one millisecond before the remaining budget is
		-- calculated. The executor rejects zero instead of silently accepting it.
		clock.spawn = function(fn, ...) return f.h.sched.delay(0.001, fn, ...) end
		local wireTimeout, sentAt, startedAt, calls
		calls = 0
		caps.fn.request = function(options)
			wireTimeout, sentAt, calls = options.Timeout, clock.ms(), calls + 1
			assert(type(wireTimeout) == "number" and wireTimeout > 0 and wireTimeout % 1 == 0, "executor requires positive integer Timeout")
			clock.wait(0.15)
			return { StatusCode = 200, Body = '{"server":"uai-relay"}', Headers = { server = "fixture" } }
		end
		local response, why = f.run(function()
			startedAt = clock.ms()
			return http.request({ url = "http://127.0.0.1:8790/api/hello", timeout = budget, identity = "none" })
		end, 0.3)
		check("probe succeeds with a strict executor", response and response.ok and why == nil and calls == 1)
		check("worker setup leaves a fractional native budget", sentAt > startedAt and (budget * 1000 - (sentAt - startedAt)) % 1000 ~= 0)
		check("local wire timeout remains within five seconds", wireTimeout >= 1 and wireTimeout <= 5 and wireTimeout % 1 == 0)
		if budget == 1 then check("one-second discovery never emits zero", wireTimeout == 1) end
		check("completed probe releases its native slot", http.workers() == 0)
		f.healthy(); f.close()
	end
end)

case("rounded native timeout cannot extend the caller deadline or release an unfinished worker", function()
	local f = F.new()
	local http, caps, clock = f.env.require("net/http"), f.env.require("runtime/caps"), f.env.require("runtime/clock")
	clock.spawn = function(fn, ...) return f.h.sched.delay(0.001, fn, ...) end
	local wireTimeout, startedAt, completedAt, calls
	calls = 0
	caps.fn.request = function(options)
		wireTimeout, calls = options.Timeout, calls + 1
		clock.wait(0.5)
		return { StatusCode = 200, Body = "late result", Headers = { server = "fixture" } }
	end
	local response, why = f.run(function()
		startedAt = clock.ms()
		local result, err = http.send({ url = "http://127.0.0.1:8790/api/hello", timeout = 1,
			deadlineMs = startedAt + 250, attempts = 3, identity = "none" })
		completedAt = clock.ms()
		return result, err
	end, 0.3)
	local entry = http.history[#http.history]
	check("fractional residual uses a positive native second", wireTimeout == 1)
	check("original absolute deadline remains authoritative", response == nil and tostring(why):find("deadline:", 1, true)
		and completedAt - startedAt >= 250 and completedAt - startedAt <= 300)
	check("deadline retains its still-running native worker", http.workers() == 1 and calls == 1)
	f.h.sched.advance(0.4)
	check("actual native completion releases the retained slot", http.workers() == 0)
	check("late completion neither retries nor rewrites the deadline outcome", calls == 1 and http.count == 1
		and http.history[1] == entry and entry.status == 0 and entry.error == why)
	f.healthy(); f.close()
end)

for _, ending in ipairs({ "deadline", "abort" }) do
	case("a worker scheduled after " .. ending .. " never dispatches", function()
		local f = F.new()
		local http, caps, clock = f.env.require("net/http"), f.env.require("runtime/caps"), f.env.require("runtime/clock")
		clock.spawn = function(fn, ...) return f.h.sched.delay(0.5, fn, ...) end
		local calls, stopped, startedAt, completedAt = 0, false, nil, nil
		caps.fn.request = function()
			calls = calls + 1
			return { StatusCode = 200, Body = "unexpected dispatch", Headers = { server = "fixture" } }
		end
		if ending == "abort" then f.h.sched.delay(0.1, function() stopped = true end) end
		local response, why = f.run(function()
			startedAt = clock.ms()
			local result, err = http.send({ url = "http://127.0.0.1:8790/api/hello", timeout = 1,
				deadlineMs = startedAt + 250, attempts = 3, identity = "none", aborted = function() return stopped end })
			completedAt = clock.ms()
			return result, err
		end, 0.3)
		local entry = http.history[#http.history]
		local elapsed = completedAt - startedAt
		check("caller settles before scheduled dispatch", response == nil and (ending == "abort" and why == "aborted" and elapsed < 250
			or ending == "deadline" and tostring(why):find("deadline:", 1, true) and elapsed >= 250 and elapsed <= 300))
		check("queued worker retains its reservation without native dispatch", calls == 0 and http.workers() == 1)
		f.h.sched.advance(0.4)
		check("late worker skips native dispatch and releases once", calls == 0 and http.workers() == 0)
		check("late scheduling cannot retry or rewrite the settled outcome", http.count == 1 and http.history[1] == entry
			and entry.status == 0 and entry.error == why)
		f.healthy(); f.close()
	end)
end

suite.finish()
