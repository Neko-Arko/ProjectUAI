-- Native relay exchanges remain owned after their short Lua wait expires.
-- Synthetic executor continuations only; does not reproduce an Android crash.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Relay poll ownership")
local case, check = suite.case, suite.check

case("timed-out polls wait for the original native exchange before dispatching again", function()
	local f = F.new()
	local http, caps = f.env.require("net/http"), f.env.require("runtime/caps")
	local owner, calls = {}, 0
	caps.fn.request = function()
		calls = calls + 1
		if calls == 1 then f.h.sched.wait(12) end
		return { StatusCode = 200, Body = "answer " .. calls }
	end
	local response, why = f.run(function()
		return http.request({ url = "http://127.0.0.1:8790/poll", identity = "none", timeout = 1, nativeOwner = owner })
	end, 1.2)
	check("timeout retains native ownership", not response and why:find("deadline:", 1, true) and calls == 1 and http.workers() == 1)
	local blocked, blockedWhy = f.run(function()
		return http.request({ url = "http://127.0.0.1:8790/poll", identity = "none", timeout = 2, nativeOwner = owner })
	end, 2.2)
	check("another wait dispatches no duplicate poll", not blocked and blockedWhy:find("capacity:", 1, true) and calls == 1 and http.workers() == 1)
	local fresh = f.run(function()
		return http.request({ url = "http://127.0.0.1:8790/poll", identity = "none", timeout = 20, nativeOwner = owner })
	end, 12)
	check("native completion permits a fresh exchange and discards its stale result", fresh and fresh.body == "answer 2" and calls == 2)
	check("completed exchanges release both ownership and native capacity", owner.pending == nil and http.workers() == 0)
	f.healthy(); f.close()
end)

local function companion()
	local f = F.new()
	f.h.services.UserInputService.TouchEnabled, f.h.services.UserInputService.MouseEnabled = true, false
	f.token, f.instance = string.rep("a", 64), "poll-owner-fixture"
	f.submissions, f.polls, f.deletes = 0, 0, 0
	local http = f.env.require("net/http")
	local function reply(value, status)
		return { StatusCode = status or 200, Body = f.h.json.encode(value) }
	end
	f.h.http.relay = function(request)
		if request.url:find("/api/hello", 1, true) then
			return reply({ ok = true, server = "uai-relay", protocol = 2, instance = f.instance,
				capabilities = { inference = { schema = 1, unlimited = true } } })
		elseif request.url:find("/api/pair", 1, true) then
			return reply({ ok = true, protocol = 2, instance = f.instance, token = f.token })
		elseif request.method == "DELETE" then
			f.deletes = f.deletes + 1
			return reply({ cancelled = true })
		elseif request.method == "POST" then
			f.submissions = f.submissions + 1
			local input = f.h.json.decode(request.body)
			f.id = input.id
			return reply({ id = input.id, state = "running" }, 202)
		end
		f.polls = f.polls + 1
		return f.onPoll(request, f.polls)
	end
	f.h.http.handler = function() error("provider fallback is not allowed") end
	f.http = http
	f.onPoll = function()
		return reply({ id = f.id, state = "completed", status = 200, body = "finished" })
	end
	check("companion is authenticated", f.run(f.env.require("net/relay_link").scan, 1))
	function f.send(stopped)
		return http.send({ url = "https://provider.fixture/v1/chat/completions", method = "POST", body = "{}", relay = true,
			aborted = stopped })
	end
	return f, reply
end

case("unlimited thinking cannot accumulate overlapping stuck polls and Stop remains independent", function()
	local f, reply = companion()
	f.onPoll = function()
		f.h.sched.wait(60)
		return reply({ id = f.id, state = "completed", status = 200, body = "late discarded answer" })
	end
	local stopped, settled, response, why = false, false, nil, nil
	f.h.sched.spawn(function()
		response, why = f.send(function() return stopped end)
		settled = true
	end)
	f.h.sched.advance(40)
	check("one unfinished native poll owns the job after repeated short deadlines", not settled and f.polls == 1 and f.http.workers() == 1)
	check("one provider submission retains its relay waiter", f.submissions == 1 and f.http.relayWorkers() == 1)
	stopped = true; f.h.sched.advance(1)
	check("Stop settles the Lua request while its native poll remains alive", settled and not response and why == "aborted" and f.http.workers() == 1)
	check("cancellation bypasses the stuck poll and targets the same job once", f.deletes == 1 and f.submissions == 1 and f.http.relayWorkers() == 0)
	f.h.sched.advance(25)
	check("late completion releases the poll without reviving or replaying inference", f.http.workers() == 0 and not response and f.polls == 1 and f.submissions == 1)
	f.healthy(); f.close()
end)

case("a recovered poll keeps its original job and normal polling cadence", function()
	local f, reply = companion()
	f.onPoll = function(_, count)
		if count == 1 then
			f.h.sched.wait(12)
			return reply({ id = f.id, state = "running" })
		end
		return reply({ id = f.id, state = "completed", status = 200, body = "recovered answer" })
	end
	local response = f.run(function() return f.send() end, 16)
	check("poll recovery returns the authoritative result", response and response.ok and response.body == "recovered answer")
	check("recovery sends one fresh poll and no inference replay", f.polls == 2 and f.submissions == 1 and f.deletes == 0)
	check("recovery releases all request ownership", f.http.workers() == 0 and f.http.relayWorkers() == 0)
	f.healthy(); f.close()
end)

suite.finish()
