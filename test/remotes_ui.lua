-- Focused native Remote Spy behavior; does not invoke outgoing hooks or traffic.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
io.stdout:setvbuf("no")
local F = require("coding_fixture")
local suite = F.suite("Remote Spy UI")
local case, check = suite.case, suite.check
local function text(root)
	local parts = {}
	for _, node in ipairs(root:GetDescendants()) do if node:IsA("TextLabel") then parts[#parts + 1] = node.Text end end
	return table.concat(parts, "\n")
end
local function contains(root, value) return text(root):find(value, 1, true) ~= nil end
local function remote(f, class, name)
	local object = f.h.Instance.new(class, f.h.workspace); object.Name = name; return object
end
local function click(f, root, name)
	local button = assert(f.h.byName(name, root), name .. " is present")
	button.Activated:Fire(); f.h.sched.advance(0.2); return button
end

case("timed incoming capture exposes pause, expiry and actual scope without rebuilding the list each second", function()
	local f = F.ui(960, 700)
	local capture, records, refs = f.env.require("runtime/remote_capture"), f.env.require("runtime/remote_store"), f.env.require("runtime/instance_refs")
	local ping = remote(f, "RemoteEvent", "TimedPing")
	capture.view.remoteId, capture.view.duration = refs.id(ping), 4
	local beforeCapture, beforeRecords = capture.changed:count(), records.changed:count()
	local spy = f.env.require("ui/code/remotes").new(f.host, function() end)
	click(f, spy.root, "StartRemoteCapture")
	check("Start observes only the selected event", capture.status == "running" and capture.state().monitored == 1)
	check("actual scope and remaining duration are visible", contains(f.h.byName("RemoteCaptureScope", spy.root), "TimedPing") and contains(f.h.byName("RemoteCaptureStatus", spy.root), "s left"))
	check("active duration cannot be changed", not f.h.byName("RemoteCaptureDuration", spy.root).Active)
	ping.OnClientEvent:Fire("hello"); f.h.sched.advance(0.2)
	local rows, initial = spy.list.items, text(f.h.byName("RemoteCaptureStatus", spy.root))
	f.h.sched.advance(1)
	check("countdown changes without replacing retained rows", spy.list.items == rows and text(f.h.byName("RemoteCaptureStatus", spy.root)) ~= initial)
	click(f, spy.root, "StartRemoteCapture")
	check("Pause explains that the timer keeps running", capture.status == "paused" and f.h.byName("CaptureCoverage", spy.root).Text:find("timer continues", 1, true))
	ping.OnClientEvent:Fire("ignored")
	check("paused recording does not admit new calls", records.state().retained == 1)
	f.h.sched.advance(4)
	check("expiry retains captured records and returns controls", capture.status == "expired" and records.state().retained == 1 and f.h.byName("RemoteCaptureDuration", spy.root).Active)
	spy.destroy(); f.h.sched.advance(2)
	check("destroy removes view subscriptions", capture.changed:count() == beforeCapture and records.changed:count() == beforeRecords)
	f.healthy(); f.close()
end)

case("call summaries update late outcomes and exact-remote filters leave capture admission unchanged", function()
	local f = F.ui(960, 700)
	local records, values, refs, capture = f.env.require("runtime/remote_store"), f.env.require("runtime/values"), f.env.require("runtime/instance_refs"), f.env.require("runtime/remote_capture")
	local first, second = remote(f, "RemoteFunction", "ReadScore"), remote(f, "RemoteFunction", "ReadInventory")
	local function record(object)
		return records.begin({ remoteId = refs.id(object), name = object.Name, className = object.ClassName, pathAtCapture = "game.Workspace." .. object.Name,
			method = "InvokeServer", direction = "outgoing", origin = "uai", sessionId = "fixture" }, values.pack(false, nil, "text", nil))
	end
	local one, two = record(first), record(second)
	local spy = f.env.require("ui/code/remotes").new(f.host, function() end)
	for _, row in ipairs(spy.list.rows) do if row.item and row.item.id == one.id then row.button.instance.Activated:Fire(); break end end
	f.h.sched.advance(0.2)
	local summary = assert(f.h.byName("RemoteCallSummary", spy.root))
	check("summary explains direction and exact argument arity", contains(summary, "Client to server") and contains(summary, "Arguments: 4") and contains(summary, "Waiting for result"))
	records.finish(one, "errored", nil, "Fixture server rejected the call"); f.h.sched.advance(0.2)
	summary = assert(f.h.byName("RemoteCallSummary", spy.root))
	check("late outcomes update the summary and error", contains(summary, "Outcome: Error") and contains(summary, "Fixture server rejected the call") and contains(summary, "Duration:"))
	click(f, spy.root, "ShowSelectedRemoteCalls")
	check("exact filter selects matching retained records", #spy.list.items == 1 and spy.list.items[1].id == one.id and capture.view.filters.remote_id == refs.id(first))
	check("filter state and Reset are visible", contains(f.h.byName("RemoteFilterSummary", spy.root), "This remote") and f.h.byName("ResetRemoteFilters", spy.root).Visible)
	check("view filtering never changes admission or removes records", next(capture.filter.include) == nil and next(capture.filter.exclude) == nil and records.get(two.id) ~= nil)
	click(f, spy.root, "ResetRemoteFilters")
	check("Reset restores all retained calls", #spy.list.items == 2 and next(capture.view.filters) == nil and capture.view.filter == "")
	spy.destroy(); f.healthy(); f.close()
end)

case("narrow and short workspaces keep the filter strip and list reachable", function()
	for _, size in ipairs({ { 320, 240 }, { 390, 700 }, { 844, 390 } }) do
		local f = F.ui(size[1], size[2]); local spy = f.env.require("ui/code/remotes").new(f.host, function() end)
		local filters = f.h.byName("RemoteViewFilters", spy.root)
		check("filter strip finishes before the call list", filters.Position.Y.Offset + filters.Size.Y.Offset <= spy.list.root.Position.Y.Offset)
		check("call list keeps usable height", spy.list.root.AbsoluteSize.Y > 60)
		if size[2] == 240 then check("short host scrolls its complete controls", spy.surfaceScroll.CanvasSize.Y.Offset > size[2]) end
		spy.destroy(); f.healthy(); f.close()
	end
end)

suite.finish()
