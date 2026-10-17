-- Focused unload regressions. Fire Destroying while children and Parent still
-- exist, matching native Roblox ordering rather than the default mock teardown.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Code UI unload")
local case, check = suite.case, suite.check

case("editor unload preserves a native compiler continuation and releases listeners", function()
	local f = F.ui(480, 320)
	local store, caps = f.env.require("runtime/code_store"), f.env.require("runtime/caps")
	assert(store.update(store.activeId(), "return 42"))
	local started, finished, cancelled, statuses = false, false, 0, 0
	local cancel = f.h.sandbox.task.cancel
	f.h.sandbox.task.cancel = function(worker) cancelled = cancelled + 1; return cancel(worker) end
	caps.exec = true
	caps.fn.loadstring = function()
		started = true
		f.h.sched.wait(0.3)
		finished = true
		return function() return 42 end
	end
	local signals = { f.env.run.Heartbeat, f.env.uis.InputBegan, f.env.uis.InputEnded, f.env.uis.WindowFocusReleased }
	local baseline = {}; for index, signal in ipairs(signals) do baseline[index] = signal:Count() end
	local editor = f.env.require("ui/code/editor").new(f.host, { onStatus = function() statuses = statuses + 1 end })
	f.h.sched.advance(0.55)
	check("compiler is suspended in host work", started and not finished)
	local before = statuses
	editor.root.Destroying:Fire()
	check("cleanup runs before native removes the editor tree", not editor.alive and editor.root.Parent == f.host and #editor.root:GetChildren() > 0)
	for index, signal in ipairs(signals) do check("global listener " .. index .. " is released", signal:Count() == baseline[index]) end
	editor.root:Destroy(); editor.destroy(); editor.setVisible(true)
	f.h.sched.advance(0.5)
	check("native compiler returns naturally without task.cancel", finished and cancelled == 0)
	check("late syntax result cannot update a destroyed editor", statuses == before and not editor.visible)
	f.healthy(); f.close()
end)

case("parent destruction releases an editor without calling its public destroy", function()
	local f = F.ui(480, 320)
	local baseline = f.env.run.Heartbeat:Count()
	local editor = f.env.require("ui/code/editor").new(f.host)
	f.host:Destroy()
	check("indirect destruction marks the editor dead", not editor.alive)
	check("indirect destruction disconnects its heartbeat", f.env.run.Heartbeat:Count() == baseline)
	f.h.sched.advance(0.6)
	f.healthy(); f.close()
end)

case("virtual lists cannot repopulate during native destruction geometry events", function()
	local f = F.ui(480, 160)
	local selected = 0
	local list = f.env.require("ui/code/list").new(f.host, { onSelect = function() selected = selected + 1 end })
	local rows = {}; for index = 1, 100 do rows[index] = { id = tostring(index), label = "Row " .. index } end
	list.set(rows)
	local added = 0
	list.root.ChildAdded:Connect(function() added = added + 1 end)
	list.root.Destroying:Connect(function()
		list.root.Size = f.h.sandbox.UDim2.fromOffset(480, 2500)
		list.root:GetPropertyChangedSignal("AbsoluteSize"):Fire()
		list.root:GetPropertyChangedSignal("CanvasPosition"):Fire()
	end)
	list.root.Destroying:Fire()
	check("destruction begins with native parent retained", list.root.Parent == f.host)
	check("geometry changes create no replacement children", added == 0 and not list.visible)
	list.visible = true; list.set(rows); list.render(); list.move(1); list.activate()
	check("late list updates and input remain inert", added == 0 and selected == 0)
	list.root:Destroy()
	f.healthy(); f.close()
end)

suite.finish()
