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
	local absent, why, _, failureKind = http.request({ url = "https://fixture.test/unavailable", identity = "none" })
	local entry = http.history[#http.history]
	check("real transport failures keep their reason", not absent and tostring(why):find("fixture network unavailable", 1, true)
		and entry.error == why and entry.status == 0 and failureKind == "transport")
	caps.fn.request = function() return { StatusCode = 200, Body = {} } end
	absent, why, _, failureKind = http.request({ url = "https://fixture.test/malformed", identity = "none" })
	check("invalid response bodies remain received response failures", not absent and tostring(why):find("malformed:", 1, true)
		and http.history[#http.history].error == why and failureKind == "response")
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

case("a selected executor can receive an exact minimal GET without changing default calls", function()
	local f = F.new()
	local http, caps = f.env.require("net/http"), f.env.require("runtime/caps")
	local defaultCalls, selectedCalls, selectedOptions, defaultOptions = 0, 0, nil, nil
	local function reply() return { StatusCode = 200, Body = "ready", Headers = { server = "fixture" } } end
	caps.fn.request = function(options) defaultCalls, defaultOptions = defaultCalls + 1, options; return reply() end
	local profile = { name = "http_request", useTimeout = false, omitEmptyHeaders = true, request = function(options)
		selectedCalls, selectedOptions = selectedCalls + 1, options
		for key in pairs(options) do assert(key == "Url" or key == "Method", "minimal executor rejects option " .. key) end
		return reply()
	end }
	local response = http.request({ url = "http://127.0.0.1:8790/api/hello", timeout = 1, identity = "none", executorProfile = profile })
	check("only the selected alias receives the minimal GET", response and response.ok and selectedCalls == 1 and defaultCalls == 0
		and selectedOptions.Url == "http://127.0.0.1:8790/api/hello" and selectedOptions.Method == "GET")
	check("response and diagnostics identify the chosen alias", response.via == "http_request" and response.entry.via == "http_request")
	response = http.request({ url = "http://127.0.0.1:8790/api/hello", timeout = 1, identity = "none" })
	check("ordinary calls retain their default executor and options", response and response.ok and response.via == "executor"
		and defaultCalls == 1 and selectedCalls == 1 and defaultOptions.Timeout == 1 and type(defaultOptions.Headers) == "table"
		and next(defaultOptions.Headers) == nil and defaultOptions.Body == nil)
	profile.request = function(options) selectedCalls, selectedOptions = selectedCalls + 1, options; return reply() end
	profile.useTimeout, profile.omitEmptyHeaders = true, false
	response = http.request({ url = "http://127.0.0.1:8790/api/hello", timeout = 1, identity = "none", executorProfile = profile })
	check("an explicitly supported profile keeps Timeout and empty Headers", response and response.ok and selectedCalls == 2 and defaultCalls == 1
		and selectedOptions.Timeout == 1 and type(selectedOptions.Headers) == "table" and next(selectedOptions.Headers) == nil)
	f.healthy(); f.close()
end)

case("selected POST transport preserves authentication and body without fallback", function()
	local f = F.new()
	local http, caps, clock = f.env.require("net/http"), f.env.require("runtime/caps"), f.env.require("runtime/clock")
	local defaultCalls, selectedCalls, selectedOptions = 0, 0, nil
	caps.fn.request = function() defaultCalls = defaultCalls + 1; error("default must not run") end
	local profile = { name = "syn.request", useTimeout = false, omitEmptyHeaders = true, request = function(options)
		selectedCalls, selectedOptions = selectedCalls + 1, options
		return { StatusCode = 202, Body = '{"state":"running"}', Headers = { server = "fixture" } }
	end }
	clock.spawn = function(fn, ...) return f.h.sched.delay(0.05, fn, ...) end
	local response, why
	f.h.sched.spawn(function() response, why = http.request({ url = "http://127.0.0.1:8790/api/inference", method = "POST",
		body = '{"id":"accepted-once"}', headers = { Authorization = "Bearer fixture", ["X-Relay-Test"] = "kept" },
		timeout = 1, identity = "none", executorProfile = profile }) end)
	profile.request, profile.name, profile.useTimeout = caps.fn.request, "request", true
	f.h.sched.advance(0.2)
	check("queued dispatch keeps the captured profile", response and response.ok and why == nil and selectedCalls == 1
		and defaultCalls == 0 and response.via == "syn.request" and selectedOptions.Timeout == nil)
	check("minimal options retain nonempty headers and the exact POST body", selectedOptions.Method == "POST"
		and selectedOptions.Body == '{"id":"accepted-once"}' and selectedOptions.Headers.Authorization == "Bearer fixture"
		and selectedOptions.Headers["Content-Type"] == "application/json" and selectedOptions.Headers["X-Relay-Test"] == "kept")
	local thrown = { name = "syn.request", useTimeout = false, omitEmptyHeaders = true, request = function()
		selectedCalls = selectedCalls + 1; error("fixture selected alias failed")
	end }
	local failed, err, _, failureKind = f.run(function() return http.request({ url = "http://127.0.0.1:8790/api/inference", method = "POST",
		body = '{"id":"second-explicit-call"}', timeout = 1, identity = "none", executorProfile = thrown }) end, 0.2)
	check("completed native failure cannot select another alias or repeat the POST", failed == nil and failureKind == "transport"
		and tostring(err):find("fixture selected alias failed", 1, true) and selectedCalls == 2 and defaultCalls == 0)
	check("failed profile diagnostics retain the selected alias", http.history[#http.history].via == "syn.request")
	f.healthy(); f.close()
end)

case("omitting native Timeout preserves the bounded waiter and native ownership", function()
	local f = F.new()
	local http, caps, clock = f.env.require("net/http"), f.env.require("runtime/caps"), f.env.require("runtime/clock")
	local defaultCalls, selectedCalls, sentOptions, completedAt = 0, 0, nil, nil
	caps.fn.request = function() defaultCalls = defaultCalls + 1; error("default must not run") end
	local profile = { name = "http_request", useTimeout = false, omitEmptyHeaders = true, request = function(options)
		selectedCalls, sentOptions = selectedCalls + 1, options
		clock.wait(0.5)
		return { StatusCode = 200, Body = "late response", Headers = { server = "fixture" } }
	end }
	local startedAt = clock.ms()
	local response, why, elapsed, failureKind = f.run(function()
		local result, err, duration, kind = http.request({ url = "http://127.0.0.1:8790/api/hello", timeout = 1,
			deadlineMs = startedAt + 250, identity = "none", executorProfile = profile })
		completedAt = clock.ms()
		return result, err, duration, kind
	end, 0.3)
	local entry = http.history[#http.history]
	check("unsupported Timeout is absent from the selected native request", sentOptions.Timeout == nil and selectedCalls == 1 and defaultCalls == 0)
	check("original deadline still settles the waiter", response == nil and tostring(why):find("deadline:", 1, true)
		and failureKind == "terminal" and elapsed >= 250 and elapsed <= 300 and completedAt - startedAt <= 300)
	check("timed out native request retains its slot", http.workers() == 1)
	f.h.sched.advance(0.4)
	check("late native completion releases once without fallback or diagnostic rewrite", http.workers() == 0 and selectedCalls == 1
		and defaultCalls == 0 and http.count == 1 and http.history[1] == entry and entry.error == why and entry.via == "http_request")
	f.healthy(); f.close()
end)

case("response failures cannot masquerade as completed native throws", function()
	local f = F.new()
	local http, caps = f.env.require("net/http"), f.env.require("runtime/caps")
	local responses = {
		false,
		{ StatusCode = 200, Body = "", Headers = {}, StatusMessage = "unknown transport failure" },
		{ StatusCode = 200, Body = ("x"):rep(http.limits.body + 1), Headers = {} },
		setmetatable({}, { __index = function() error("response field failed") end }),
	}
	for _, nativeResponse in ipairs(responses) do
		caps.fn.request = function() return nativeResponse end
		local result, why, elapsed, failureKind = http.request({ url = "http://127.0.0.1:8790/api/hello", identity = "none" })
		check("received invalid response forbids alias fallback", result == nil and type(why) == "string" and type(elapsed) == "number" and failureKind == "response")
	end
	caps.fn.request = function() error("unsupported option Timeout") end
	local result, why, _, failureKind = http.request({ url = "http://127.0.0.1:8790/api/hello", identity = "none" })
	check("completed option rejection keeps its origin for discovery classification", result == nil and failureKind == "transport"
		and tostring(why):find("unsupported option Timeout", 1, true))
	f.healthy(); f.close()
end)

suite.finish()
