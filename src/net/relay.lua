-- The relay owns the provider connection; every executor exchange stays short.
-- A lost submission is retried with the same ID, never as a second inference
-- request. The endpoint is resolved per call so a companion that appears or
-- restarts mid-session is picked up without a reload.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local dispose = env.require("runtime/dispose")
	local transport = env.require("net/transport")
	local alive, pending = true, {}
	local M = {}

	local function noRelay()
		return { status = 599, body = util.encode({ error = { message =
			"This request needs a local relay. Start the Project UAI Companion app on this device, "
			.. "or enable the web bridge in Cowork settings." } }), headers = {}, via = "web", terminal = true }, nil
	end

	function M.request(spec, headers, call)
		local endpoint = spec.relayEndpoint or transport.endpoint()
		if not endpoint then return noRelay() end
		local base, token, target = endpoint.base, endpoint.token, endpoint.target
		-- Keep one native path for the entire job, including receipt recovery and
		-- cancellation. A later discovery scan cannot redirect an accepted request.
		local selected = endpoint.executorProfile
		local executorProfile = selected and { request = selected.request, name = selected.name,
			useTimeout = selected.useTimeout, omitEmptyHeaders = selected.omitEmptyHeaders }
		local via = target == "companion" and "relay" or "web"
		local timeout = math.max(1, math.min(300, tonumber(spec.timeout) or 180))
		local id = "inference_" .. env.services.HttpService:GenerateGUID(false)
		local deadline = math.min(tonumber(spec.deadlineMs) or math.huge,
			clock.ms() + math.max(1, math.min(300, tonumber(spec.timeout) or 120)) * 1000)
		local unlimited = transport.unlimited(spec, endpoint)
		if unlimited then deadline = math.huge end
		local ended
		local function short(method, path, body)
			if clock.ms() >= deadline then return nil, "deadline: relay request budget expired" end
			return call({ url = base .. path, method = method, body = body,
				headers = { Authorization = "Bearer " .. token }, identity = "none", silent = true,
				waitForSlot = true, timeout = math.min(5, (deadline - clock.ms()) / 1000), deadlineMs = deadline,
				aborted = ended, executorProfile = executorProfile })
		end
		local cancelled = false
		local function cancel()
			if cancelled then return end
			cancelled = true
			clock.spawn(function()
				pcall(call, { url = base .. "/api/inference/" .. id, method = "DELETE",
					headers = { Authorization = "Bearer " .. token }, identity = "none", silent = true, timeout = 2,
					waitForSlot = true, executorProfile = executorProfile })
			end)
		end
		pending[id] = cancel
		ended = function()
			-- Health determines the next request's route. An accepted request keeps
			-- its original endpoint while recovering the same job; only changed
			-- credentials/settings, unload or caller cancellation invalidate it.
			local current = transport.endpoint(target)
			return not alive or not current or current.target ~= target or current.token ~= token
				or current.base ~= base or (current.instance or "") ~= (endpoint.instance or "")
				or (spec.aborted and spec.aborted())
		end
		local function failure(message)
			pending[id] = nil
			return { status = 599, body = util.encode({ error = { message = message } }), headers = {},
				via = via, terminal = true }, nil
		end
		if token == "" then
			if target == "companion" then
				return failure("The companion relay is not paired. Open Cowork settings and pair again.")
			end
			return failure("Web runtime needs the bridge token in Cowork settings.")
		end
		local hello = short("GET", "/api/hello")
		if ended() then pending[id] = nil; return nil, "aborted" end
		local info = hello and hello.ok and util.decode(hello.body)
		if type(info) ~= "table" or info.protocol ~= 2 or not info.instance then
			if target == "companion" then
				return failure("The companion relay did not answer. Start the Project UAI Companion app, then retry.")
			end
			return failure("Web runtime cannot connect. Start the updated bridge/server.js and check its token.")
		end
		local capability = type(info.capabilities) == "table" and info.capabilities.inferencePreview
		local previews = target == "cowork" and type(spec.onFrame) == "function"
			and type(capability) == "table" and capability.schema == 1
		local cursor, frozen = 0, false
		local function integer(value)
			return type(value) == "number" and value >= 0 and value < 9007199254740992 and value % 1 == 0
		end
		local function limitPreview()
			if frozen then return end
			frozen = true
			if not ended() then pcall(spec.onFrame, { uaiPreviewLimited = true }) end
		end
		local function feedPreview(page)
			if not previews or frozen or page == nil then return end
			if type(page) ~= "table" or page.schema ~= 1 or not integer(page.after) or not integer(page.cursor)
				or page.after > cursor or page.cursor < page.after or type(page.frames) ~= "table" or #page.frames > 128 then
				limitPreview(); return
			end
			if page.cursor < cursor then return end
			if page.gap then limitPreview(); return end
			local previous = page.after
			-- Validate the complete page before displaying any part. Preview errors
			-- cannot cancel a paid request or make its authoritative body unusable.
			for _, frame in ipairs(page.frames) do
				if type(frame) ~= "table" or not integer(frame.seq) or frame.seq <= previous or frame.seq > page.cursor
					or (frame.channel ~= "text" and frame.channel ~= "reasoning") or type(frame.text) ~= "string"
					or #frame.text > 8192 or not util.validUtf8(frame.text) then limitPreview(); return end
				previous = frame.seq
			end
			for _, frame in ipairs(page.frames) do
				if ended() then return end
				if frame.seq > cursor then
					local delta = frame.channel == "text" and { content = frame.text } or { reasoning_content = frame.text }
					local model = type(page.model) == "string" and #page.model <= 1200 and page.model or nil
					if not pcall(spec.onFrame, { model = model, choices = { { delta = delta } } }) then limitPreview(); return end
				end
			end
			cursor = page.cursor
			if page.limited then limitPreview() end
		end
		if clock.ms() >= deadline then return failure("Relay request deadline reached before submission.") end
		local input = { id = id, instance = info.instance, url = spec.url, headers = headers,
			body = spec.body, sessionId = spec.sessionId }
		if target == "companion" then
			local inference = type(info.capabilities) == "table" and info.capabilities.inference
			local acceptsUnlimited = type(inference) == "table" and inference.schema == 1 and inference.unlimited == true
			-- Kotlin's protocol uses integer seconds. Fractional remaining budgets
			-- previously produced invalid JSON requests before inference could start.
			input.timeout = unlimited and acceptsUnlimited and 0 or math.max(1, math.ceil(math.min(timeout, (deadline - clock.ms()) / 1000)))
		end
		local payload = util.encode(input)
		local submitted, attempts = false, 0
		while clock.ms() < deadline do
			if ended() then cancel(); pending[id] = nil; return nil, "aborted" end
			local response
			if not submitted then
				attempts = attempts + 1
				response = short("POST", "/api/inference", payload)
			else response = short("GET", "/api/inference/" .. id .. (previews and not frozen and ("?after=" .. cursor) or "")) end
			if ended() then cancel(); pending[id] = nil; return nil, "aborted" end
			if response and response.ok then
				local job = util.decode(response.body)
				if type(job) ~= "table" or job.id ~= id then cancel(); return failure("Invalid relay response; inference was not resubmitted.") end
				submitted = true
				if job.state == "running" then feedPreview(job.preview) end
				if ended() then cancel(); pending[id] = nil; return nil, "aborted" end
				if job.state == "completed" then
					pending[id] = nil
					return { status = job.status, headers = job.headers or {}, body = job.body or "", via = via, inferenceId = id }
				elseif job.state ~= "running" then
					return failure(job.error or ("Relay job " .. tostring(job.state) .. "; inference was not resubmitted."))
				end
			elseif response and response.status >= 400 and response.status < 500 then
				cancel()
				local decoded = util.decode(response.body or "")
				local reason = type(decoded) == "table" and type(decoded.error) == "string" and util.truncate(decoded.error, 400) or "Check the bridge token and restart state."
				if target == "companion" and reason == "invalid executor request" then
					reason = "The companion could not read the executor's message. Update UAI Relay and reload the UAI script. Resetting pairing will not fix request encoding."
				end
				return failure("Relay rejected the request (" .. response.status .. "): " .. reason .. " Inference was not resubmitted.")
			elseif not submitted and attempts >= 3 then
				cancel(); return failure("Could not confirm relay submission; stopped without resubmitting inference.")
			end
			local slept = 0
			while slept < 1 and clock.ms() < deadline do
				if ended() then cancel(); pending[id] = nil; return nil, "aborted" end
				slept = slept + (clock.wait(0.1) or 0.1)
			end
		end
		cancel()
		return failure("Relay result deadline reached; inference was cancelled rather than retried.")
	end
	dispose.add(function()
		alive = false
		for _, cancel in pairs(pending) do cancel() end
		pending = {}
	end, "relayed inference")
	return M
end
