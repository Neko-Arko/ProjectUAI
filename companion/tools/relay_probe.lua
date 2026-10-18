-- Run on the TARGET PHONE in its executor. No UI or provider/API key is needed.
-- Start delay_fixture.js first. Configure UAI_RELAY_PROBE before loading this file:
-- UAI_RELAY_PROBE = { url = "http://192.168.1.10:8791/probe", port = 8790 }
-- See companion/tools/README.md. Output contains timings and categories, never tokens.
local options = type(UAI_RELAY_PROBE) == "table" and UAI_RELAY_PROBE or {}
local fn = request or http_request
	or (type(syn) == "table" and syn.request)
	or (type(http) == "table" and http.request)
	or (type(fluxus) == "table" and fluxus.request)
if type(fn) ~= "function" then print("[relay-probe] FAIL no_executor_request") return end
local json = game:GetService("HttpService")
local pause = task and task.wait or wait
local port = tonumber(options.port) or 8790
local base = "http://127.0.0.1:" .. tostring(port)
local budget = math.max(60, math.min(300, tonumber(options.waitSeconds) or 100))
local pending, token, failure = {}, nil, nil
local report = { schema = 1, passed = false, calls = 0, polls = 0, pollErrors = 0,
	maxCallMs = 0, longResponse = false, idempotent = false, cancelled = false }
pcall(function() report.touchEnabled = game:GetService("UserInputService").TouchEnabled == true end)
local function stop(code) failure = code; error(code, 0) end
local function decode(text)
	if type(text) ~= "string" or #text > 65536 then return nil end
	local ok, value = pcall(json.JSONDecode, json, text)
	return ok and type(value) == "table" and value or nil
end
local function call(path, method, body)
	local headers = { ["Content-Type"] = "application/json" }
	if token then headers.Authorization = "Bearer " .. token end
	local started = tick()
	local ok, response = pcall(fn, { Url = base .. path, Method = method or "GET", Headers = headers,
		Body = body, Timeout = 5 })
	local elapsed = math.max(0, math.floor((tick() - started) * 1000 + 0.5))
	report.calls = report.calls + 1
	report.maxCallMs = math.max(report.maxCallMs, elapsed)
	if not ok or type(response) ~= "table" then return 0, nil end
	return tonumber(response.StatusCode or response.Status) or 0, decode(response.Body or response.ResponseData)
end
local function valid(info, instance)
	return info and info.server == "uai-relay" and info.protocol == 2 and info.instance == instance
end
local function jobCall(path, method, body, id)
	local status, job = call(path, method, body)
	if (status ~= 200 and status ~= 202) or not job or job.id ~= id then stop("job_not_confirmed") end
	return job
end
local function cancel(id)
	call("/api/inference/" .. id, "DELETE")
end
local function run()
	if port < 1 or port > 65535 or port % 1 ~= 0 then stop("invalid_port") end
	if type(options.url) ~= "string" or not options.url:match("^https?://[^/@]+/probe$") then stop("configure_delay_fixture_url") end
	local status, hello = call("/api/hello")
	if status ~= 200 or not hello or type(hello.instance) ~= "string" or not valid(hello, hello.instance) then stop("companion_not_found") end
	local pairStatus, pair = call("/api/pair", "POST", json:JSONEncode({ client = "ProjectUAI-RelayProbe", version = "1.1.0", protocol = 2 }))
	if pairStatus ~= 200 or not pair or pair.ok ~= true or pair.protocol ~= 2 or pair.instance ~= hello.instance or type(pair.token) ~= "string"
		or #pair.token ~= 64 or not pair.token:match("^[a-f0-9]+$") then stop("pairing_not_confirmed") end
	token = pair.token
	local authStatus, info = call("/api/status")
	if authStatus ~= 200 or not valid(info, hello.instance) then stop("authentication_not_confirmed") end
	local capability = info.capabilities and info.capabilities.inference
	report.unlimited = type(capability) == "table" and capability.schema == 1 and capability.unlimited == true
	local id = "uai_probe_" .. json:GenerateGUID(false):gsub("[^%w_-]", "")
	local function submitBody(jobId)
		return json:JSONEncode({ id = jobId, instance = hello.instance, url = options.url,
			headers = { ["Content-Type"] = "application/json" }, body = json:JSONEncode({ probeId = jobId }),
			timeout = report.unlimited and 0 or 180 })
	end
	local payload = submitBody(id)
	pending[id] = true
	local started = tick()
	local job = jobCall("/api/inference", "POST", payload, id)
	if job.state ~= "running" then stop("long_job_not_running") end
	print("[relay-probe] Request accepted. Waiting for the controlled long response.")
	job = jobCall("/api/inference", "POST", payload, id)
	if job.state ~= "running" then stop("duplicate_job_not_running") end
	local nextProgress = 10
	while tick() - started < budget do
		pause(1)
		local pollStatus, polled = call("/api/inference/" .. id)
		report.polls = report.polls + 1
		if pollStatus == 200 and polled and polled.id == id then
			job = polled
			if job.state == "completed" then break end
			if job.state ~= "running" then stop("long_job_terminal_before_response") end
		elseif pollStatus >= 400 and pollStatus < 500 then stop("poll_rejected")
		else report.pollErrors = report.pollErrors + 1 end
		if tick() - started >= nextProgress then
			print(("[relay-probe] Still polling the same job after %ds."):format(nextProgress))
			nextProgress = nextProgress + 10
		end
	end
	if job.state ~= "completed" then stop("observation_budget_expired") end
	pending[id] = nil
	report.elapsedMs = math.floor((tick() - started) * 1000 + 0.5)
	local answer = decode(job.body)
	if job.status ~= 200 or not answer or answer.ok ~= true or answer.fixture ~= "uai-relay-delay-v1" or answer.probeId ~= id then stop("fixture_response_invalid") end
	if type(answer.elapsedMs) ~= "number" or answer.elapsedMs < 35000 or report.elapsedMs < 35000 then stop("response_did_not_exceed_30_seconds") end
	report.longResponse = true
	if answer.dispatches ~= 1 then stop("upstream_dispatched_more_than_once") end
	report.idempotent = true
	local cancelId = id .. "_cancel"
	pending[cancelId] = true
	job = jobCall("/api/inference", "POST", submitBody(cancelId), cancelId)
	if job.state ~= "running" then stop("cancel_job_not_running") end
	pause(2)
	cancel(cancelId)
	job = jobCall("/api/inference/" .. cancelId, "GET", nil, cancelId)
	if job.state ~= "cancelled" then stop("cancellation_not_confirmed") end
	pending[cancelId] = nil
	report.cancelled = true
	if report.maxCallMs > 5000 then stop("executor_call_exceeded_five_seconds") end
	report.passed = true
end
local ok = pcall(run)
if not ok then report.error = failure or "probe_interrupted" end
for id in pairs(pending) do cancel(id) end
token = nil
print("[relay-probe] " .. json:JSONEncode(report))
if report.passed then
	print("[relay-probe] PASS: long forwarding, same-ID replay, short executor calls and cancellation on this execution host.")
else
	print("[relay-probe] FAIL: " .. tostring(report.error) .. ". Keep this timing report; no provider key was used.")
end
