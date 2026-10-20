-- Folded traces retain source without sending it through native TextLabel layout.
-- Mock checks bound assignment/ownership work, not native Roblox performance.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Reasoning retention")
local case, check = suite.case, suite.check

case("long folded traces defer native text assignment and resize work until opened", function()
	local f = F.ui(390, 844)
	f.h.services.UserInputService.TouchEnabled = true
	local responsive = f.env.require("ui/responsive")
	responsive.refresh("fixture touch")
	local P, markdown = f.env.require("ui/primitives"), f.env.require("ui/markdown")
	local measure, inline = P.measureText, markdown.inline
	local longMeasures, formatted = 0, 0
	P.measureText = function(value, options)
		if #tostring(value or "") > 4096 then longMeasures = longMeasures + 1 end
		return measure(value, options)
	end
	markdown.inline = function(value)
		formatted = formatted + 1
		return inline(value)
	end
	local source = ("**Observed** evidence. "):rep(9000)
	local thought = f.env.require("ui/chat/message").reasoning(f.host, source, 1)
	local body = thought.body
	check("construction never exposes the long folded source to a native label", body.Text == ""
		and body.AutomaticSize == f.h.sandbox.Enum.AutomaticSize.None)
	local writes, largest = 0, 0
	body:GetPropertyChangedSignal("Text"):Connect(function()
		writes = writes + 1; largest = math.max(largest, #body.Text)
	end)
	for index = 1, 20 do thought.setText(source .. tostring(index)) end
	f.h.setViewport(844, 390); responsive.refresh("fixture rotation")
	f.h.settle(0.3)
	check("folded updates and rotation assign no source, format no Markdown and measure no body", writes == 0
		and largest == 0 and formatted == 0 and longMeasures == 0)
	local header = f.h.byName("ReasoningHeader", thought.root)
	f.h.click(header)
	local rendered = body.Text
	check("opening still exposes the complete latest trace", rendered:find("<b>Observed</b>", 1, true)
		and rendered:sub(-2) == "20" and #rendered > 190000)
	check("opening enables native sizing and keeps a bounded viewport", body.AutomaticSize == f.h.sandbox.Enum.AutomaticSize.Y
		and f.h.byName("Aside", thought.root).Size.Y.Offset <= f.env.require("ui/theme").size.thinkingViewport)
	check("opening formats only once", formatted == 1 and longMeasures > 0)
	f.h.click(header)
	check("folding releases native text and automatic sizing", body.Text == "" and not body.RichText
		and body.AutomaticSize == f.h.sandbox.Enum.AutomaticSize.None)
	local foldedWrites = writes
	for index = 1, 10 do thought.setText(source .. "next " .. index, true) end
	check("later folded updates release stale formatting without new native writes", writes == foldedWrites
		and formatted == 1 and f.h.byName("ReasoningExtent", thought.root).Text == "Excerpt")
	f.h.click(header)
	check("opening the changed trace formats the latest source once", formatted == 2 and body.Text:sub(-7) == "next 10")
	f.h.click(header); f.h.click(header)
	check("reopening unchanged traces reuses the cached formatted bytes", formatted == 2 and body.Text:sub(-7) == "next 10")
	thought.root:Destroy()
	P.measureText, markdown.inline = measure, inline
	f.healthy(); f.close()
end)

case("folded previews retain exact provider text outside presentation", function()
	local f = F.ui()
	local source = ("Original provider reasoning. "):rep(3000)
	local session = f.env.require("agent/session").newThread()
	local context = session.ctx
	context.pushAssistant({ content = "Answer", reasoning = source })
	local view = f.env.require("ui/chat/view").new(f.host)
	view.attach(session); f.h.settle(0.2); session.busy = true
	session.emit("assistant:preview", { streamId = "retention", reasoning = source, text = "", model = "fixture" })
	local thought = view.preview.thoughtHandle
	check("preview retains exact text in the session while the label stays empty", session.livePreview.reasoning == source
		and thought.body.Text == "")
	session.emit("assistant:reasoning", { streamId = "retention", text = source })
	session.emit("assistant:complete", { streamId = "retention" })
	check("durable reconciliation keeps the same folded disclosure", view.run.thought == thought and thought.body.Text == ""
		and f.h.byName("ReasoningExtent", thought.root).Text == "Excerpt")
	check("presentation does not clip model context or persisted reasoning", context.messages[1].reasoning == source
		and context.serialise().messages[1].reasoning == source)
	f.h.click(f.h.byName("ReasoningHeader", thought.root))
	check("the bounded retained excerpt is readable on demand", thought.body.Text ~= ""
		and thought.body.Text:find("characters omitted", 1, true))
	view.destroy(); f.healthy(); f.close()
end)

suite.finish()
