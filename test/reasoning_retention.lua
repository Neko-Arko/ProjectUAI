-- Folded traces retain source without sending it through native TextLabel layout.
-- Mock checks bound assignment/ownership work, not native Roblox performance.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Reasoning retention")
local case, check = suite.case, suite.check

case("touch reasoning defers folded work and bounds expanded formatting and native layout", function()
	local f = F.ui(390, 844)
	f.h.services.UserInputService.TouchEnabled = true
	f.h.services.UserInputService.MouseEnabled = false
	local responsive = f.env.require("ui/responsive")
	responsive.refresh("fixture touch")
	local P, markdown = f.env.require("ui/primitives"), f.env.require("ui/markdown")
	local measure, inline, plain = P.measureText, markdown.inline, markdown.plain
	local bodyMeasures, largestMeasure, formatted, largestFormat, plainCalls, largestPlain = 0, 0, 0, 0, 0, 0
	P.measureText = function(value, options)
		if options and options.role == "small" then
			bodyMeasures = bodyMeasures + 1; largestMeasure = math.max(largestMeasure, #tostring(value or ""))
		end
		return measure(value, options)
	end
	markdown.inline = function(value)
		formatted = formatted + 1
		largestFormat = math.max(largestFormat, #value)
		return inline(value)
	end
	markdown.plain = function(value)
		plainCalls = plainCalls + 1; largestPlain = math.max(largestPlain, #value)
		return plain(value)
	end
	local source = ("**Observed** caf\195\169 evidence. "):rep(9000)
	local thought = f.env.require("ui/chat/message").reasoning(f.host, source, 1)
	local body = thought.body
	check("construction never exposes the long folded source to a native label", body.Text == ""
		and body.AutomaticSize == f.h.sandbox.Enum.AutomaticSize.None
		and f.h.byName("ReasoningExtent", thought.root).Text == "Excerpt")
	local writes, largest = 0, 0
	body:GetPropertyChangedSignal("Text"):Connect(function()
		writes = writes + 1; largest = math.max(largest, #body.Text)
	end)
	for index = 1, 20 do thought.setText(source .. tostring(index)) end
	f.h.setViewport(844, 390); responsive.refresh("fixture rotation")
	f.h.settle(0.3)
	check("folded updates and rotation assign no source, format no Markdown and measure no body", writes == 0
		and largest == 0 and formatted == 0 and plainCalls == 0 and bodyMeasures == 0)
	local header = f.h.byName("ReasoningHeader", thought.root)
	f.h.click(header)
	local rendered = body.Text
	check("opening shows both ends of a labelled excerpt with valid UTF-8 and inline emphasis", rendered:find("<b>Observed</b>", 1, true)
		and rendered:find("characters omitted", 1, true) and rendered:sub(-2) == "20"
		and #rendered <= 32768 and f.env.require("runtime/util").validUtf8(rendered))
	check("opening enables native sizing and keeps a bounded viewport", body.AutomaticSize == f.h.sandbox.Enum.AutomaticSize.Y
		and f.h.byName("Aside", thought.root).Size.Y.Offset <= f.env.require("ui/theme").size.thinkingViewport)
	check("formatting, plain conversion and native measurement receive only bounded presentation", formatted == 1
		and plainCalls == 1 and bodyMeasures > 0 and largestFormat <= 8192 and largestPlain <= 8192 and largestMeasure <= 8192)
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
	check("later updates never hand the full trace to native layout", largest <= 32768
		and largestFormat <= 8192 and largestPlain <= 8192 and largestMeasure <= 8192)
	thought.root:Destroy()
	P.measureText, markdown.inline, markdown.plain = measure, inline, plain
	f.healthy(); f.close()
end)

case("expanded touch reasoning falls back before oversized RichText enters native layout", function()
	local f = F.ui(390, 844)
	f.h.services.UserInputService.TouchEnabled = true; f.h.services.UserInputService.MouseEnabled = false
	f.env.require("ui/responsive").refresh("fixture touch")
	f.env.require("runtime/config").set("ui.expandThinking", true)
	local source = ("`a` "):rep(4000) .. "latest tail"
	local markdown, util = f.env.require("ui/markdown"), f.env.require("runtime/util")
	local shown = util.truncate(source, 8192)
	check("real inline formatting expands the bounded code spans beyond the native rich limit", #shown <= 8192
		and #markdown.inline(shown) > 32768)
	local thought = f.env.require("ui/chat/message").reasoning(f.host, source, 1)
	check("auto-expanded touch trace uses bounded raw text without malformed RichText", thought.body.Text == shown
		and not thought.body.RichText and f.h.byName("ReasoningExtent", thought.root).Text == "Excerpt")
	thought.setText("**Short** reasoning")
	check("short updates restore normal formatted reasoning and visible extent", thought.body.RichText
		and thought.body.Text == "<b>Short</b> reasoning" and f.h.byName("ReasoningExtent", thought.root).Text ~= "Excerpt")
	thought.root:Destroy(); f.healthy(); f.close()
end)

case("desktop reasoning keeps its complete trace while touch transitions update the excerpt", function()
	local f = F.ui(1280, 720)
	local responsive = f.env.require("ui/responsive")
	responsive.refresh("fixture desktop")
	local source = ("Desktop source. "):rep(4000) .. "final tail"
	local thought = f.env.require("ui/chat/message").reasoning(f.host, source, 1)
	f.h.click(f.h.byName("ReasoningHeader", thought.root))
	check("desktop opening preserves complete native text", thought.body.Text == source
		and f.h.byName("ReasoningExtent", thought.root).Text ~= "Excerpt")
	f.h.services.UserInputService.TouchEnabled = true
	responsive.refresh("fixture desktop touchscreen")
	check("a pointer desktop retains the complete trace", thought.body.Text == source)
	f.h.services.UserInputService.MouseEnabled = false
	responsive.refresh("fixture touch-only tablet")
	check("touch-only input immediately bounds an already expanded trace", #thought.body.Text <= 32768
		and thought.body.Text:find("characters omitted", 1, true)
		and f.h.byName("ReasoningExtent", thought.root).Text == "Excerpt")
	f.h.services.UserInputService.TouchEnabled = false; f.h.services.UserInputService.MouseEnabled = true
	responsive.refresh("fixture desktop restored")
	check("returning to pointer input restores original presentation", thought.body.Text == source
		and f.h.byName("ReasoningExtent", thought.root).Text ~= "Excerpt")
	thought.root:Destroy(); f.healthy(); f.close()
end)

case("touch previews and expanded excerpts retain exact provider text outside presentation", function()
	local f = F.ui(390, 844)
	f.h.services.UserInputService.TouchEnabled = true; f.h.services.UserInputService.MouseEnabled = false
	f.env.require("ui/responsive").refresh("fixture touch")
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
		and thought.body.Text:find("characters omitted", 1, true) and #thought.body.Text <= 32768)
	check("expanding the excerpt still leaves original context and persistence untouched", context.messages[1].reasoning == source
		and context.serialise().messages[1].reasoning == source)
	view.destroy(); f.healthy(); f.close()
end)

suite.finish()
