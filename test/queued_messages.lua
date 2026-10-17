-- Real session/loop interleavings with a deterministic scheduler and local files.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Queued agent messages")
local case, check = suite.case, suite.check
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end
local function answer(text, calls) return { content = text or "Done", reasoning = "", toolCalls = calls or {}, finish = "stop" } end
local function users(messages)
	local out = {}; for _, row in ipairs(messages) do if row.role == "user" then out[#out + 1] = row.content end end
	return out
end
local function fixture(options)
	local f = F.new(); f.tools({ "fs" })
	f.env.require("runtime/config").set("agent.fallback", false)
	f.env.require("runtime/config").set("agent.compaction", false)
	f.env.require("runtime/config").set("agent.unlimitedTurns", false)
	local providers = f.env.require("provider/registry")
	local record = providers.blank("custom")
	record.label, record.model, record.models = "Queue fixture", "fixture-model", { "fixture-model" }
	record.baseUrl, record.apiKey = "https://queue.fixture/v1", "fixture-key"
	assert(providers.save(record)); providers.setActive(record.id)
	f.sessions = f.env.require("agent/session")
	f.session = assert(f.sessions.newThread(options or { id = "queue-fixture", ephemeral = true }))
	f.requests, f.events, f.active, f.peak = {}, {}, 0, 0
	f.session.events:connect(function(event) f.events[#f.events + 1] = event end)
	f.loaded["provider/chat"] = {
		contextOverflow = function() return false end,
		complete = function(_, request)
			f.active = f.active + 1; f.peak = math.max(f.peak, f.active)
			f.requests[#f.requests + 1] = f.env.require("runtime/util").deepCopy(request.messages)
			local index = #f.requests
			local result, why
			if f.respond then result, why = f.respond(index, request) else result = answer() end
			f.active = f.active - 1
			return result, why
		end,
	}
	function f.done() f.healthy(); f.close() end
	return f
end

case("inference follow-ups continue after text and preserve one request owner", function()
	local f, settled = fixture(), {}
	f.respond = function(index, request)
		if index == 1 then f.abortProbe = request.aborted; f.h.sched.wait(0.2); return answer("First response") end
		return answer("Follow-ups complete")
	end
	local function callback(text, receipt) settled[#settled + 1] = { text = text, status = receipt.status } end
	check("initial send accepted", f.session.send("Original", callback))
	local epoch, tool = f.session.toolEpoch, f.session.toolContext()
	local a, receipt = f.session.send("First follow-up", callback, nil, nil, { messageId = "follow-one" })
	local b = f.session.send("Second follow-up", callback)
	check("busy sends return a queued receipt", a and b and receipt.queued and receipt.messageId == "follow-one")
	check("sending keeps the active worker and cancellation token", f.session.busy and f.session.toolEpoch == epoch and not tool.aborted() and not f.abortProbe())
	check("pending text does not mutate the in-flight prompt or history", #users(f.requests[1]) == 1 and #users(f.session.ctx.messages) == 1)
	local queued = f.session.queueSnapshot()
	check("pending snapshot is ordered and isolated", queued.count == 2 and queued.items[1].text == "First follow-up" and queued.items[2].text == "Second follow-up")
	queued.items[1].text = "changed"
	check("snapshot mutation cannot edit a follow-up", f.session.queueSnapshot().items[1].text == "First follow-up")
	f.h.sched.advance(1)
	check("text response continues with one later inference", #f.requests == 2 and f.peak == 1 and not f.session.busy)
	check("later inference contains both follow-ups in order", table.concat(users(f.requests[2]), "|") == "Original|First follow-up|Second follow-up")
	check("normal steering stays in the same turn and epoch", f.session.turns == 1 and f.session.toolEpoch == epoch)
	check("all applied messages settle with the final result", #settled == 3 and settled[1].text == "Follow-ups complete" and settled[3].status == "succeeded")
	local texts = {}; for _, event in ipairs(f.events) do if event.kind == "assistant:text" then texts[#texts + 1] = event end end
	check("intermediate text does not claim finality", #texts == 2 and texts[1].final == false and texts[2].final == true)
	check("consumption empties the pending list", f.session.queueSnapshot().count == 0)
	f.done()
end)

case("a complete tool batch settles before a follow-up reaches the next prompt", function()
	local f, finished = fixture(), {}
	for index, name in ipairs({ "queue_read_a", "queue_read_b" }) do
		local delay = index == 1 and 0.25 or 0.1
		assert(f.registry.register({ name = name, group = "fixture", risk = "read", description = "Queue fixture read",
			parameters = { type = "object", properties = {} }, run = function(_, context)
				f.h.sched.wait(delay); check("steering did not abort " .. name, not context.aborted())
				finished[#finished + 1] = name; return name .. " result"
			end }))
	end
	f.respond = function(index)
		if index > 1 then check("both tools completed before inference", #finished == 2); return answer("Tools complete") end
		return answer("Reading", {
			{ id = "tool-a", type = "function", ["function"] = { name = "queue_read_a", arguments = "{}" } },
			{ id = "tool-b", type = "function", ["function"] = { name = "queue_read_b", arguments = "{}" } },
		})
	end
	assert(f.session.send("Read both"))
	f.h.sched.advance(0.04)
	local epoch = f.session.toolEpoch
	check("tool-time follow-up is accepted", f.session.send("Then compare them"))
	f.h.sched.advance(1)
	local second, roles = f.requests[2], {}
	for _, row in ipairs(second or {}) do if row.role ~= "system" then roles[#roles + 1] = row.role end end
	check("assistant calls and all ordered results precede the user follow-up", table.concat(roles, ",") == "user,assistant,tool,tool,user"
		and second[#second - 2].tool_call_id == "tool-a" and second[#second - 1].tool_call_id == "tool-b")
	check("tool steering never replaces the worker", f.session.toolEpoch == epoch and f.peak == 1 and #f.requests == 2)
	f.done()
end)

case("Stop, provider errors, step limits and deadlines hold unapplied input for Resume", function()
	for _, mode in ipairs({ "stop", "provider", "steps", "deadline" }) do
		local f = fixture({ id = "hold-" .. mode, ephemeral = true, maxTurns = mode == "steps" and 1 or nil,
			budgetSeconds = mode == "deadline" and 0.1 or nil })
		local pendingCallback, originalStatus = 0, nil
		f.respond = function(index)
			if index == 1 then f.h.sched.wait(0.2); if mode == "provider" then return nil, "Fixture provider unavailable" end end
			return answer("Complete")
		end
		assert(f.session.send("Original", function(_, result) originalStatus = result.status end))
		assert(f.session.send("Held follow-up", function() pendingCallback = pendingCallback + 1 end))
		if mode == "stop" then assert(f.session.abort()) end
		f.h.sched.advance(1)
		local queue = f.session.queueSnapshot()
		check(mode .. " leaves unapplied input held and visible", queue.held and queue.count == 1 and queue.items[1].text == "Held follow-up" and not f.session.busy)
		check(mode .. " does not consume or complete a pending message", #f.requests == 1 and #users(f.session.ctx.messages) == 1 and pendingCallback == 0)
		check(mode .. " settles the original outcome", originalStatus == (mode == "stop" and "cancelled" or "failed"))
		check(mode .. " explicitly resumes", f.session.resumeQueue())
		f.h.sched.advance(0.3)
		check(mode .. " applies the held input once", #f.requests == 2 and pendingCallback == 1 and f.session.queueSnapshot().count == 0 and not f.session.busy)
		f.done()
	end
end)

case("a new idle send resumes held messages in their original order", function()
	local f = fixture()
	f.respond = function(index) if index == 1 then f.h.sched.wait(0.1); return nil, "Fixture outage" end; return answer() end
	assert(f.session.send("Original")); assert(f.session.send("Earlier follow-up")); f.h.sched.advance(0.2)
	check("new send accepted while held", f.session.send("New instruction"))
	f.h.sched.advance(0.2)
	check("new instruction follows the held input", #f.requests == 2 and table.concat(users(f.requests[2]), "|") == "Original|Earlier follow-up|New instruction")
	f.done()
end)

case("message IDs deduplicate admissions and removal releases bounded capacity", function()
	local f, removed = fixture(), 0
	f.respond = function(index) if index == 1 then f.h.sched.wait(0.3) end; return answer() end
	assert(f.session.send("Original", nil, nil, nil, { messageId = "original-id" }))
	for index = 1, 16 do
		check("bounded follow-up " .. index .. " accepted", f.session.send("Pending " .. index,
			function(_, result) if result.status == "cancelled" then removed = removed + 1 end end,
			nil, nil, { messageId = "pending-" .. index }))
	end
	local duplicate, receipt = f.session.send("Changed duplicate", nil, nil, nil, { messageId = "pending-1" })
	check("a duplicate receipt does not consume another slot", duplicate and receipt.queued and f.session.queueSnapshot().count == 16)
	local overflow, why = f.session.send("Too many")
	check("seventeenth pending message is refused", not overflow and has(why, "full"))
	check("removing a queued message settles its callback", f.session.removeQueued("pending-4") and removed == 1)
	check("freed capacity can be used", f.session.send("Replacement"))
	f.h.sched.advance(1)
	local sent = table.concat(users(f.requests[2]), "|")
	check("removed and duplicate content never dispatches", not has(sent, "Pending 4|") and not has(sent, "Changed duplicate") and has(sent, "Replacement"))
	local count = #f.requests
	check("consumed IDs remain idempotent", f.session.send("Try again", nil, nil, nil, { messageId = "original-id" }) and #f.requests == count)
	check("missing queue removal is a recoverable refusal", not f.session.removeQueued("missing"))
	f.done()
end)

case("attachment preparation keeps reservation order and a compact verified pointer", function()
	local f = fixture()
	local store = f.env.require("runtime/attachments")
	local save = store.save
	store.save = function(text, name) f.h.sched.wait(0.2); return save(text, name) end
	local body = "START_SOURCE\n" .. string.rep("local message = 'queued'\n", 600) .. "END_SOURCE"
	local accepted
	f.h.sched.spawn(function() accepted = { f.session.send(body, nil, nil, nil, { messageId = "slow-file" }) } end)
	check("large initial input is visibly preparing", f.session.preparing and f.session.queueSnapshot().items[1].state == "preparing" and not f.session.busy)
	assert(f.session.send("After that file"))
	check("a later ready message cannot overtake preparation", #f.requests == 0 and f.session.queueSnapshot().count == 2 and not f.session.queueSnapshot().held)
	f.h.sched.advance(0.5)
	check("initial preparation starts the queued work", accepted and accepted[1] and #f.requests == 1 and not f.session.preparing)
	local input = users(f.requests[1])
	local path = input[1]:match("Path: ([^\n]+)")
	check("the prompt contains a compact pointer followed by the next instruction", #input == 2 and #input[1] < 650 and input[2] == "After that file"
		and not has(input[1], "START_SOURCE") and not has(input[1], "END_SOURCE"))
	check("saved attachment preserves the exact input", path and f.env.require("runtime/fsx").readUser(path) == body)
	f.done()
end)

case("failed, stopped and removed preparations never dispatch late or block successors", function()
	for _, mode in ipairs({ "failed", "stop", "remove" }) do
		local f, accepted = fixture(), nil
		local store, body = f.env.require("runtime/attachments"), string.rep("pending source\n", 1000)
		local save = store.save
		store.save = function(text) f.h.sched.wait(0.2); if mode == "failed" then return nil, "Fixture disk refusal" end; return save(text) end
		f.h.sched.spawn(function() accepted = { f.session.send(body, nil, nil, nil, { messageId = "preparation" }) } end)
		assert(f.session.send("Successor"))
		if mode == "stop" then f.session.abort() elseif mode == "remove" then assert(f.session.removeQueued("preparation")) end
		f.h.sched.advance(0.5)
		check(mode .. " preparation returns a refusal so its caller keeps the draft", accepted and accepted[1] == false and type(accepted[2]) == "string")
		check(mode .. " clears the preparation flag", not f.session.preparing)
		if mode == "stop" then
			check("Stop holds the prepared successor", #f.requests == 0 and f.session.queueSnapshot().held and f.session.queueSnapshot().count == 1)
			assert(f.session.resumeQueue()); f.h.sched.advance(0.1)
		end
		check(mode .. " successor survives without the cancelled source", #f.requests == 1 and table.concat(users(f.requests[1]), "|") == "Successor")
		f.done()
	end
end)

case("late attachment completion after provider failure cannot resume itself", function()
	local f = fixture()
	f.respond = function(index) if index == 1 then f.h.sched.wait(0.1); return nil, "Fixture outage" end; return answer() end
	assert(f.session.send("Original"))
	local store, accepted = f.env.require("runtime/attachments"), nil
	local save = store.save
	store.save = function(text) f.h.sched.wait(0.3); return save(text) end
	f.h.sched.spawn(function() accepted = { f.session.send(string.rep("late source\n", 1000)) } end)
	f.h.sched.advance(0.5)
	check("late preparation is accepted but stays held", accepted and accepted[1] and #f.requests == 1 and not f.session.busy and f.session.queueSnapshot().held)
	assert(f.session.resumeQueue()); f.h.sched.advance(0.1)
	check("explicit Resume applies the prepared reference", #f.requests == 2 and has(users(f.requests[2])[2], "Path: "))
	f.done()
end)

case("terminal-event follow-ups get a settled worker and callback statuses remain isolated", function()
	local f, sent, results = fixture(), false, {}
	f.respond = function(index) f.h.sched.wait(0.05); return answer("Answer " .. index) end
	f.session.events:connect(function(event)
		if event.kind == "turn:end" and not sent then sent = true; assert(f.session.send("Terminal follow-up", function(text, result) results[2] = { text, result.status } end)) end
	end)
	assert(f.session.send("Original", function(text, result) results[1] = { text, result.status } end))
	f.h.sched.advance(0.5)
	check("terminal follow-up runs once after the previous worker", #f.requests == 2 and f.peak == 1 and f.session.turns == 2)
	check("each callback retains its own final reply", results[1][1] == "Answer 1" and results[2][1] == "Answer 2" and results[1][2] == "succeeded")
	local first, later, started
	f.respond = function(index) f.h.sched.wait(0.05); return answer("Answer " .. index) end
	assert(f.session.send("Another original", function(_, result) first = result.status end))
	local off = f.sessions.listChanged:connect(function()
		if not started and not f.session.busy then
			started = true; assert(f.session.send("Immediate successor", function(_, result) later = result.status end)); f.session.abort()
		end
	end)
	f.h.sched.advance(0.5); off()
	check("successor cancellation cannot change the predecessor outcome", first == "succeeded" and later == "cancelled" and #f.requests == 4)
	f.done()
end)

case("queue persistence restores held, validates files again, and preserves malformed files", function()
	local f = fixture({ id = "persisted-queue" })
	f.respond = function() f.h.sched.wait(0.2); return nil, "Fixture outage" end
	local savedFile = assert(f.env.require("runtime/attachments").save("verified attachment"))
	assert(f.session.send("Original"))
	assert(f.session.send("Read the attachment", nil, { savedFile }, nil, { messageId = "persisted-follow" }))
	f.h.sched.advance(0.4)
	local path = "UAI/sessions/" .. f.session.id .. ".json"
	local saved = assert(f.h.files[path])
	local data = f.h.json.decode(saved)
	check("prepared input persists separately from applied conversation history", #data.queue.items == 1 and data.queue.items[1].id == "persisted-follow" and #users(data.context.messages) == 1)
	f.sessions.threads[f.session.id] = nil
	check("ordinary session restore loads the pending queue", f.sessions.restore() == 1)
	local restored = assert(f.sessions.get(f.session.id))
	check("restoration never starts queued work", restored.queueSnapshot().held and restored.queueSnapshot().count == 1 and not restored.busy and #f.requests == 1)
	f.h.files["UAI/" .. savedFile.path] = nil
	assert(restored.resumeQueue()); f.h.sched.advance(0.2)
	check("missing restored attachment stays held without inference", #f.requests == 1 and restored.queueSnapshot().held and has(restored.queueSnapshot().reason, "missing or changed"))
	f.h.files["UAI/" .. savedFile.path] = "verified attachment"
	f.respond = function() return answer() end
	assert(restored.resumeQueue()); f.h.sched.advance(0.2)
	check("restored attachment can resume after repair", #f.requests == 2 and restored.queueSnapshot().count == 0)
	f.sessions.threads[restored.id] = nil
	data.queue.items[1].id = "../invalid"
	local malformed = f.h.json.encode(data); f.h.files[path] = malformed
	check("malformed saved queues are skipped without deleting history", f.sessions.restore() == 0 and f.h.files[path] == malformed)
	f.done()
end)

case("image references remain session-owned and compact while queued", function()
	local f = fixture()
	f.loaded["net/bridge_connection"] = { enabled = function() return true end }
	f.respond = function(index) if index == 1 then f.h.sched.wait(0.2) end; return answer() end
	local picture = { url = "uai-image://pic_fixture/" .. string.rep("a", 64), sessionId = f.session.id,
		mediaType = "image/png", bytes = 128, name = "Fixture image" }
	assert(f.session.send("Original"))
	check("image-only follow-up is accepted", f.session.send("", nil, nil, { picture }))
	picture.sessionId = "other-session"
	check("cross-session image is refused", not f.session.send("Invalid picture", nil, nil, { picture }))
	local queue = f.session.queueSnapshot()
	check("pending image remains a compact immutable reference", queue.count == 1 and queue.items[1].images[1].sessionId == f.session.id and queue.items[1].images[1].url:match("^uai%-image://"))
	f.h.sched.advance(0.5)
	local history = f.session.ctx.messages
	local attached; for _, row in ipairs(history) do if row.images and #row.images > 0 then attached = row end end
	check("safe consumption carries the image into context", attached and attached.content == "Please look at the attached image." and attached.images[1].sessionId == f.session.id)
	f.done()
end)

case("clear and unload settle queued callbacks without permitting reentry", function()
	for _, mode in ipairs({ "clear", "unload" }) do
		local f, cancelled, reentered = fixture({ id = "lifetime-" .. mode }), 0, nil
		f.respond = function() f.h.sched.wait(0.1); return nil, "Fixture outage" end
		assert(f.session.send("Original"))
		assert(f.session.send("Pending", function(_, result)
			cancelled = cancelled + (result.status == "cancelled" and 1 or 0)
			reentered = f.session.send("Unexpected callback send")
		end))
		f.h.sched.advance(0.2)
		if mode == "clear" then f.session.clear() else f.close() end
		check(mode .. " cancels pending callbacks exactly once", cancelled == 1 and f.session.queueSnapshot().count == 0)
		check(mode .. " refuses callback reentry", reentered == false and #f.requests == 1)
		if mode == "unload" then
			local data = f.h.json.decode(f.h.files["UAI/sessions/" .. f.session.id .. ".json"])
			check("unload preserves prepared follow-ups before clearing callbacks", #data.queue.items == 1)
		end
		f.healthy(); if mode == "clear" then f.close() end
	end
end)

suite.finish()
