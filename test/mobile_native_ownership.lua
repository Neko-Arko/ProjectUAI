-- Native transport scheduling regressions; synthetic continuations, no Android.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F, luau = require("workspace_fixture"), require("luau")
local suite = F.suite("Mobile native ownership")
local case, check = suite.case, suite.check

local function fixture(mobile)
	local f = F.new()
	f.h.services.UserInputService.TouchEnabled, f.h.services.UserInputService.MouseEnabled = mobile ~= false, mobile == false
	f.http, f.caps = f.env.require("net/http"), f.env.require("runtime/caps")
	return f
end

case("repeated discovery and new jobs share the unfinished native mobile exchange", function()
	local f = fixture()
	local calls = 0
	f.caps.fn.request = function()
		calls = calls + 1
		if calls == 1 then f.h.sched.wait(30) end
		return { StatusCode = 200, Body = "answer " .. calls }
	end
	local _, why = f.run(function()
		return f.http.request({ url = "http://127.0.0.1:8790/api/inference/old", timeout = 1, nativeOwner = {} })
	end, 1.2)
	check("old job retains its native exchange", why:find("deadline:", 1, true) and calls == 1 and f.http.workers() == 1)
	local link = f.env.require("net/relay_link")
	for _ = 1, 3 do
		local ok, reason = f.run(link.probe, 5.2)
		check("a new discovery scan dispatches no overlapping native call", not ok and reason:find("capacity", 1, true) and calls == 1)
	end
	local absent, blocked = f.run(function()
		return f.http.request({ url = "http://127.0.0.1:8790/api/inference/new", timeout = 1, nativeOwner = {} })
	end, 1.2)
	check("a new job cannot replace old native ownership", not absent and blocked:find("capacity:", 1, true) and calls == 1)
	f.h.sched.advance(15)
	local response = f.http.request({ url = "https://fixture.test/fresh", timeout = 1 })
	check("actual native completion permits fresh dispatch", response and response.body == "answer 2" and calls == 2 and f.http.workers() == 0)
	f.healthy(); f.close()
end)

case("cancellation has one independent lane and repeated Stop cannot accumulate calls", function()
	local f = fixture()
	local calls, deletes = 0, 0
	f.caps.fn.request = function(spec)
		calls = calls + 1
		if spec.Method == "DELETE" then deletes = deletes + 1 end
		f.h.sched.wait(20)
		return { StatusCode = 200, Body = "late" }
	end
	f.run(function() return f.http.request({ url = "http://127.0.0.1:8790/poll", timeout = 1 }) end, 1.2)
	f.run(function() return f.http.request({ url = "http://127.0.0.1:8790/job", method = "DELETE", timeout = 1, nativeControl = true }) end, 1.2)
	check("Stop dispatches while the main native call remains stuck", calls == 2 and deletes == 1 and f.http.workers() == 2)
	local _, why = f.run(function()
		return f.http.request({ url = "http://127.0.0.1:8790/job2", method = "DELETE", timeout = 1, nativeControl = true })
	end, 1.2)
	check("a stuck cancellation also retains its own lane", why:find("capacity:", 1, true) and calls == 2 and deletes == 1)
	f.h.sched.advance(21)
	check("both native completions release capacity", f.http.workers() == 0)
	f.healthy(); f.close()
end)

case("unload and a replacement module preserve unfinished mobile ownership", function()
	local f = fixture()
	local calls = 0
	f.caps.fn.request = function()
		calls = calls + 1
		if calls == 1 then f.h.sched.wait(15) end
		return { StatusCode = 200, Body = "generation " .. calls }
	end
	f.run(function() return f.http.request({ url = "https://fixture.test/old", timeout = 1 }) end, 1.2)
	f.close()
	-- Reload the actual factory with the same process globals and native function.
	local file = assert(io.open("src/net/http.lua", "rb")); local source = file:read("*a"); file:close()
	local chunk = assert(luau.load(source, "net/http-replacement")); setfenv(chunk, f.h.sandbox)
	local replacement = chunk()(f.env)
	local _, why = f.run(function() return replacement.request({ url = "https://fixture.test/new", timeout = 1 }) end, 1.2)
	check("unload cannot free a lane still running in native code", why:find("capacity:", 1, true) and calls == 1)
	f.h.sched.advance(14)
	local response = replacement.request({ url = "https://fixture.test/new", timeout = 1 })
	check("late old completion releases the shared lane without reviving its result", response and response.body == "generation 2" and calls == 2)
	f.healthy(); f.close()
end)

case("DataModel and executor aliases use the same mobile native lane", function()
	local f = fixture()
	local posts, aliases = 0, 0
	f.h.sandbox.game.HttpPost = function()
		posts = posts + 1; f.h.sched.wait(12)
		return f.h.json.encode({ schema = 1, status = 200, body = "late" })
	end
	local profile = { request = f.env.require("net/relay_datamodel").request, name = "HttpGet/HttpPost", useTimeout = false }
	f.run(function()
		return f.http.request({ url = "http://127.0.0.1:8790/api/status", headers = { Authorization = "Bearer " .. string.rep("a", 64) },
			timeout = 1, executorProfile = profile })
	end, 1.2)
	local alias = { request = function() aliases = aliases + 1; return { StatusCode = 200, Body = "alias" } end, name = "alias" }
	local _, why = f.run(function()
		return f.http.request({ url = "http://127.0.0.1:8790/api/hello", timeout = 1, executorProfile = alias })
	end, 1.2)
	check("switching native entry points cannot bypass ownership", why:find("capacity:", 1, true) and posts == 1 and aliases == 0)
	f.h.sched.advance(11)
	local response = f.http.request({ url = "http://127.0.0.1:8790/api/hello", timeout = 1, executorProfile = alias })
	check("completed DataModel worker permits the alias", response and response.body == "alias" and aliases == 1)
	f.healthy(); f.close()
end)

case("desktop requests retain parallel native capacity", function()
	local f = fixture(false)
	local calls = 0
	f.caps.fn.request = function()
		calls = calls + 1; local number = calls
		if number == 1 then f.h.sched.wait(10) end
		return { StatusCode = 200, Body = "desktop " .. number }
	end
	f.run(function() return f.http.request({ url = "https://fixture.test/slow", timeout = 1 }) end, 1.2)
	local response = f.http.request({ url = "https://fixture.test/fast", timeout = 1 })
	check("desktop can dispatch beside an unfinished native call", calls == 2 and response and response.body == "desktop 2")
	f.h.sched.advance(10); f.healthy(); f.close()
end)

case("silent replies skip diagnostic text processing and logged excerpts are bounded first", function()
	local f = fixture()
	local util, original = f.env.require("runtime/util"), nil
	original = util.ellipsis
	local largest, invocations = 0, 0
	util.ellipsis = function(text, limit)
		largest, invocations = math.max(largest, #tostring(text)), invocations + 1
		return original(text, limit)
	end
	f.caps.fn.request = function() return { StatusCode = 200, Body = string.rep("body ", 100000) } end
	f.http.request({ url = "http://127.0.0.1:8790/poll", silent = true })
	check("silent poll performs no diagnostic normalization", invocations == 0 and #f.http.history == 0)
	f.http.request({ url = "https://fixture.test/answer" })
	check("large response is shortened before whitespace normalization", invocations == 1 and largest < 1800 and #f.http.history[1].response <= 400)
	f.healthy(); f.close()
end)

suite.finish()
