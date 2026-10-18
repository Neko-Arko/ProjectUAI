-- Diagnostic script control-flow checks only. Simulated time is not phone proof.
package.path = "test/mock/?.lua;" .. package.path
local json = require("json")
local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end
local function run(options, file)
	options = options or {}
	local now, jobs, outputs, submits, deletes = 0, {}, {}, {}, 0
	local token = ("d"):rep(64)
	local function response(status, body) return { StatusCode = status, Body = json.encode(body) } end
	local info = { ok = true, server = options.wrongServer and "other" or "uai-relay", protocol = 2, instance = "inst-probe",
		capabilities = { inference = { schema = 1, unlimited = true } } }
	local env = setmetatable({ UAI_RELAY_PROBE = { url = "http://fixture.test:8791/probe" },
		print = function(line) outputs[#outputs + 1] = line end,
		tick = function() return now end, task = { wait = function(seconds) now = now + seconds end },
		game = { GetService = function(_, name)
			if name == "UserInputService" then return { TouchEnabled = true } end
			return { JSONEncode = function(_, value) return json.encode(value) end, JSONDecode = function(_, value) return json.decode(value) end,
				GenerateGUID = function() return "00000000-0000-0000-0000-000000000001" end }
		end },
		request = function(spec)
			now = now + (options.slowCalls and 6 or 0.001)
			check(spec.Url:match("^http://127%.0%.0%.1:8790/api/"), "executor contacts only companion")
			local route = spec.Url:match("8790(.*)$")
			if route == "/api/hello" then return response(200, info) end
			if route == "/api/pair" then return response(options.refusePair and 403 or 200,
				{ ok = true, protocol = 2, instance = "inst-probe", token = token, error = "secret-refusal-body" }) end
			check(spec.Headers.Authorization == "Bearer " .. token, "private route has bearer")
			if route == "/api/status" then return response(200, info) end
			if route == "/api/inference" then
				local body = json.decode(spec.Body)
				submits[#submits + 1] = body
				check(body.timeout == 0, "negotiated unlimited submit")
				check(body.headers.Authorization == nil, "fixture gets no pairing token")
				jobs[body.id] = jobs[body.id] or { id = body.id, started = now, state = "running" }
				return response(202, jobs[body.id])
			end
			local id = route:match("^/api/inference/(.+)$")
			local job = jobs[id]
			if not job then return response(404, {}) end
			if spec.Method == "DELETE" then deletes = deletes + 1; job.state = "cancelled"; return response(200, { cancelled = true }) end
			if options.poll404 then return response(404, { error = "secret-refusal-body" }) end
			if job.state == "running" and now - job.started >= (options.fast and 1 or 45) then
				job.state, job.status = "completed", 200
				job.body = json.encode({ fixture = "uai-relay-delay-v1", ok = true, probeId = options.wrongNonce and "wrong" or id,
					elapsedMs = options.fast and 1000 or 45000, dispatches = options.duplicate and 2 or 1 })
			end
			return response(200, job)
		end,
	}, { __index = _G })
	setfenv(assert(loadfile(file or "companion/tools/relay_probe.lua")), env)()
	local output = table.concat(outputs, "\n")
	check(not output:find(token, 1, true) and not output:find("secret-refusal-body", 1, true), "output has no secrets or response dump")
	local report
	for _, line in ipairs(outputs) do
		if line:match("^%[relay%-probe%] {") then report = json.decode(line:sub(15)) end
	end
	return report, submits, deletes, output
end

local success, submits, deletes = run()
check(success and success.passed and success.longResponse and success.idempotent and success.cancelled, "complete successful diagnostic")
check(#submits == 3 and submits[1].id == submits[2].id and submits[3].id ~= submits[1].id, "only deliberate duplicate and cancellation job")
check(deletes == 1, "successful run cancels only its cancellation job")
for _, case in ipairs({
	{ wrongServer = true, expected = "companion_not_found" },
	{ refusePair = true, expected = "pairing_not_confirmed" },
	{ fast = true, expected = "response_did_not_exceed_30_seconds" },
	{ duplicate = true, expected = "upstream_dispatched_more_than_once" },
	{ wrongNonce = true, expected = "fixture_response_invalid" },
	{ slowCalls = true, expected = "executor_call_exceeded_five_seconds" },
	{ poll404 = true, expected = "poll_rejected" },
}) do
	local report = run(case)
	check(report and not report.passed and report.error == case.expected, "refuses false success: " .. case.expected)
end
local _, _, _, loopback = run({}, "companion/tools/loopback_probe.lua")
check(loopback:find("PASS:", 1, true), "basic loopback validates authentication")
local _, rejected, _, wrong = run({ wrongServer = true }, "companion/tools/loopback_probe.lua")
check(not wrong:find("PASS:", 1, true) and #rejected == 0, "basic probe rejects a wrong server")
print("probe contract checks passed: " .. checks .. " (scripted relay and simulated time, not a device)")
