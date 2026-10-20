-- Native chat scroll ownership against measured fixtures. The mock publishes
-- canvas geometry; it does not emulate Roblox touch routing or elastic motion.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local Layout = require("chat_layout")
local suite = F.suite("Mobile scrolling")
local case, check = suite.case, suite.check

local function mobile()
	local f = F.ui(390, 300)
	local input = f.h.services.UserInputService
	input.TouchEnabled, input.MouseEnabled, input.KeyboardEnabled = true, false, false
	f.env.require("ui/responsive").init(f.env.root)
	f.env.require("ui/theme").rebuild()
	return f
end

local function history(session, count)
	for index = 1, count do
		session.emit("user", { text = "Question " .. index })
		session.emit("assistant:text", { text = "Answer " .. index .. ": " .. string.rep("Readable history. ", 20) })
	end
end

case("the chat welcome can scroll and retains its reading position", function()
	local f = mobile()
	local session = f.env.require("agent/session").newThread()
	-- Supply a measured welcome height independently of native text shaping,
	-- including recreation when returning to an empty conversation.
	local home = f.env.require("ui/panels/home")
	local card = home.card
	home.card = function(...)
		local root = card(...)
		root.AutomaticSize = f.h.sandbox.Enum.AutomaticSize.None
		root.Size = f.h.sandbox.UDim2.new(1, 0, 0, 1200)
		return root
	end
	local view = f.env.require("ui/chat/view").new(f.host)
	view.attach(session)
	Layout.settle(f.h, view, 0.2)
	local scroll = view.scroll.instance
	check("welcome initially stays at its top", view.pinned and scroll.CanvasPosition.Y == 0)
	Layout.scroll(f.h, view, 240)
	Layout.settle(f.h, view, 0.2)
	check("scrolling welcome releases its top follow", not view.pinned and scroll.CanvasPosition.Y == 240)
	f.host.Size = f.h.sandbox.UDim2.fromOffset(390, 180)
	Layout.settle(f.h, view, 0.2)
	check("keyboard-sized reflow retains the welcome reading offset", scroll.CanvasPosition.Y == 240)
	view.setVisible(false); view.setVisible(true)
	Layout.settle(f.h, view, 0.2)
	check("returning to welcome preserves its saved position", not view.pinned and session.viewState.y == 240 and scroll.CanvasPosition.Y == 240)
	local bottom = scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y
	Layout.scroll(f.h, view, bottom)
	Layout.settle(f.h, view, 0.2)
	check("the end of welcome does not snap back to its top", not view.pinned and scroll.CanvasPosition.Y == bottom)
	check("welcome keeps native vertical scrolling enabled", scroll.ScrollingEnabled and scroll.ScrollingDirection == f.h.sandbox.Enum.ScrollingDirection.Y)
	session.emit("user", { text = "Start the conversation" })
	Layout.settle(f.h, view, 0.3)
	check("sending replaces welcome and resumes normal follow", not view.welcomeCard and view.pinned)
	f.healthy(); view.destroy(); f.close()
end)

case("a swipe during initial history replay overrides automatic follow", function()
	local f = mobile()
	local session = f.env.require("agent/session").newThread()
	history(session, 35)
	local view = f.env.require("ui/chat/view").new(f.host)
	view.attach(session)
	check("long history is still replaying after its first slice", view.replaying)
	Layout.scroll(f.h, view, 80)
	check("native canvas movement releases follow while replay continues", view.replaying and not view.pinned)
	Layout.settle(f.h, view, 1)
	check("later replay slices preserve the chosen reading position", not view.replaying and not view.pinned and math.abs(view.scroll.instance.CanvasPosition.Y - 80) < 1)
	local y = view.scroll.instance.CanvasPosition.Y
	session.emit("assistant:text", { text = "A new live reply" })
	Layout.settle(f.h, view, 0.3)
	check("live output leaves that position under the reader's control", not view.pinned and math.abs(view.scroll.instance.CanvasPosition.Y - y) < 1)
	f.h.click(f.host:FindFirstChild("Latest", true))
	Layout.settle(f.h, view, 0.3)
	check("Latest explicitly resumes automatic follow", view.pinned)
	f.healthy(); view.destroy(); f.close()
end)

case("a swipe while returning to hidden updates survives incremental replay", function()
	local f = mobile()
	local session = f.env.require("agent/session").newThread()
	history(session, 10)
	local view = f.env.require("ui/chat/view").new(f.host)
	view.attach(session); Layout.settle(f.h, view, 0.6)
	view.setVisible(false)
	history(session, 20)
	view.setVisible(true)
	check("returning history is incrementally replaying", view.replaying)
	Layout.scroll(f.h, view, 120)
	check("returning replay accepts the reader's changed position", not view.pinned)
	Layout.settle(f.h, view, 1)
	check("incremental completion keeps the earlier content readable", not view.replaying and not view.pinned and math.abs(view.scroll.instance.CanvasPosition.Y - 120) < 1)
	check("all retained conversation events remain available", #session.log == 60)
	f.healthy(); view.destroy(); f.close()
end)

suite.finish()
