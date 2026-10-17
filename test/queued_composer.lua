-- Native composer and bridge integration around real delayed inference.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local passed = 0
local function check(label, value) assert(value, label); passed = passed + 1; print("ok " .. label) end
local h = envMock.new()
local requests, commands, receipts, state = {}, {}, {}, nil
local responseDelay = 3
h.http.handler = function(req)
	if req.url:find("/api/agent/inbox", 1, true) then
		local batch = commands; commands = {}
		return { StatusCode = 200, Body = h.json.encode({ commands = batch }), delay = 0.1 }
	elseif req.url:find("/api/agent/ack", 1, true) then
		for _, receipt in ipairs(h.json.decode(req.body).results or {}) do receipts[receipt.id] = receipt end
		return { StatusCode = 200, Body = "{}" }
	elseif req.url:find("/api/agent/events", 1, true) then
		state = h.json.decode(req.body).state or state
		return { StatusCode = 200, Body = "{}" }
	elseif req.url:find("queue.fixture", 1, true) and req.method == "POST" then
		requests[#requests + 1] = h.json.decode(req.body)
		return { StatusCode = 200, delay = responseDelay, Body = h.json.encode({ choices = {
			{ message = { role = "assistant", content = "Finished" }, finish_reason = "stop" } } }) }
	end
	return { StatusCode = 404, Body = "{}" }
end
local app = assert(h.boot()); h.settle(0.2)
app.config.set("bridge.autoDiscover", false)
local record = app.providers.blank("custom")
record.id, record.baseUrl, record.apiKey, record.model = "queue-ui", "https://queue.fixture/v1", "fixture-key", "fixture-model"
record.models, record.stream = { record.model }, false
assert(app.providers.save(record, { force = true })); app.providers.setActive(record.id)
local session, composer = app.sessions.current(), app.app.chatPanel.composer
local function send(text)
	composer.field.set(text); h.click(h.byName("Send", composer.shell)); h.settle(0.1)
end
send("First message")
check("initial message starts work", session.busy and #requests == 1)
check("Stop has its own visible control", h.byName("Stop", composer.shell).Visible)
send("Follow up without stopping")
check("busy send queues and clears accepted draft", session.queueSnapshot().count == 1 and composer.field.get() == "")
check("follow-up does not cancel the active request", session.busy and not session.aborted() and #requests == 1)
check("pending queue is visible", h.byName("PendingMessages", composer.shell).Visible)
h.settle(3.2)
check("queued follow-up reaches the next inference", #requests == 2 and h.json.encode(requests[2].messages):find("Follow up without stopping", 1, true))
send("Keep this pending")
h.click(h.byName("Stop", composer.shell)); h.settle(3.5)
check("Stop holds unconsumed messages", not session.busy and session.queueSnapshot().held and session.queueSnapshot().count == 1)
h.click(h.byName("PendingMessages", composer.shell)); h.settle(0.1)
check("held queue offers explicit resume", h.byName("ResumeQueue").Visible)
local pendingId = session.queueSnapshot().items[1].id
h.click(h.byName("RemoveQueued_" .. pendingId)); h.settle(0.2)
check("individual pending removal is reflected in the composer", session.queueSnapshot().count == 0 and not h.byName("PendingMessages", composer.shell).Visible)
h.click(h.byName("QueueDone")); h.settle(0.2)

-- A bridge send retries its command receipt instead of adding another follow-up.
responseDelay = 20
send("Parent request for bridge steering")
app.config.set("bridge.port", 8795); app.config.set("bridge.token", "queue-fixture")
app.config.set("bridge.enabled", true); h.settle(0.3)
commands = { { type = "send", commandId = "queued-browser", sessionId = session.id, text = "Browser follow-up" } }
h.settle(1.4)
check("bridge returns a queued receipt", receipts["queued-browser"] and receipts["queued-browser"].ok and receipts["queued-browser"].data.queued)
commands = { { type = "send", commandId = "queued-browser", sessionId = session.id, text = "Browser follow-up" } }
h.settle(1.2)
check("repeated bridge receipt cannot duplicate a queued message", session.queueSnapshot().count == 1)
check("bridge snapshots expose queue and real context metadata", state and state.queue.count == 1 and state.context.sessionId == session.id and state.providers[1].modelInfo)
commands = { { type = "queue:remove", commandId = "remove-browser", sessionId = session.id, messageId = "queued-browser" },
	{ type = "setting", commandId = "effort-off", sessionId = session.id, path = "agent.effort", value = "off" } }
h.settle(1.4)
check("bridge queue removal uses the owned message identity", receipts["remove-browser"] and receipts["remove-browser"].ok and session.queueSnapshot().count == 0)
check("bridge accepts provider-default reasoning", receipts["effort-off"] and receipts["effort-off"].ok and app.config.get("agent.effort") == "off")
app.destroy(); h.settle(0.5)
check("native widgets release without asynchronous errors", #h.errors() == 0 and #h.instanceState.typeErrors == 0)
print("queued composer: " .. passed .. " checks passed")
